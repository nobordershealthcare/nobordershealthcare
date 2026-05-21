package normalizer

import (
	"context"
	"encoding/hex"
	"fmt"
	"log/slog"

	"golang.org/x/crypto/sha3"

	"github.com/nobordershealthcare/normalization/cdr"
	"github.com/nobordershealthcare/normalization/encryption"
	"github.com/nobordershealthcare/normalization/kafka"
	"github.com/nobordershealthcare/normalization/lookup"
)

// Pipeline reads from the WORM Kafka topic, normalizes each event, and writes
// to the CDR. Offsets are committed only after a successful CDR write.
type Pipeline struct {
	consumer       *kafka.Consumer
	reviewProducer *kafka.ReviewProducer
	writer         *cdr.Writer
	rawKeyFetcher  cdr.KeyFetcher // fetches the per-patient AES key for raw blob decryption
	log            *slog.Logger
}

// NewPipeline creates a Pipeline with all required dependencies.
func NewPipeline(
	consumer *kafka.Consumer,
	review *kafka.ReviewProducer,
	writer *cdr.Writer,
	rawKeyFetcher cdr.KeyFetcher,
	log *slog.Logger,
) *Pipeline {
	return &Pipeline{
		consumer:       consumer,
		reviewProducer: review,
		writer:         writer,
		rawKeyFetcher:  rawKeyFetcher,
		log:            log,
	}
}

// Run starts the normalization loop. It blocks until ctx is cancelled.
// Returning from Run closes the Kafka consumer.
func (p *Pipeline) Run(ctx context.Context) error {
	p.log.Info("normalization pipeline started")
	defer p.log.Info("normalization pipeline stopped")

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		msg, err := p.consumer.FetchMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			p.log.Error("kafka fetch failed", "err", err)
			continue
		}

		event, err := p.consumer.Decode(msg)
		if err != nil {
			// Undecodable message: log (no PII) and skip — do NOT commit so
			// the DLQ handler can inspect it on restart.
			p.log.Error("decode failed — skipping",
				"partition", msg.Partition,
				"offset", msg.Offset,
			)
			continue
		}

		// Validate hash inputs before any processing.
		if err := validateHashes(event.UserHash, event.DocHash); err != nil {
			p.log.Error("invalid hashes in event",
				"event_id", event.EventID,
				"err", err,
			)
			// Commit to advance past the poison pill — it can never be corrected.
			_ = p.consumer.CommitMessage(ctx, msg)
			continue
		}

		if err := p.process(ctx, event); err != nil {
			// Transient error (Vault, ScyllaDB): do NOT commit; retry on restart.
			p.log.Error("process event failed",
				"event_id", event.EventID,
				"err", err,
			)
			continue
		}

		// CDR write succeeded — commit the offset.
		if err := p.consumer.CommitMessage(ctx, msg); err != nil {
			p.log.Error("commit failed",
				"event_id", event.EventID,
				"partition", msg.Partition,
				"offset", msg.Offset,
				"err", err,
			)
		}
	}
}

// process decrypts the raw event blob, normalizes it, and writes to the CDR.
func (p *Pipeline) process(ctx context.Context, event *kafka.RawClinicalEvent) error {
	// Fetch per-patient key and decrypt the raw clinical document.
	key, err := p.rawKeyFetcher(ctx, event.UserHash)
	if err != nil {
		return fmt.Errorf("process %s: key fetch: %w", event.EventID, err)
	}
	rawDoc, err := encryption.Decrypt(key, event.EncryptedBlob)
	zeroSlice(key)
	if err != nil {
		return fmt.Errorf("process %s: decrypt raw blob: %w", event.EventID, err)
	}
	defer zeroSlice(rawDoc)

	// SHA3-256(EventID) is the audit linkage stored in the composition.
	sourceHash := sha3HexString([]byte(event.EventID))

	// Dispatch to the appropriate parser based on source format.
	switch event.SourceFormat {
	case "fhir_r4":
		return p.processFHIRR4(ctx, event, rawDoc, sourceHash)
	default:
		// Unsupported format: emit a review flag and skip.
		// Never discard — the WORM Kafka topic retains the original.
		flag := lookup.ReviewFlag{
			EventID:     event.EventID,
			UserHash:    event.UserHash,
			DocHash:     event.DocHash,
			UnknownCode: event.SourceFormat,
			CodeSystem:  "SOURCE_FORMAT",
		}
		go func() {
			if err := p.reviewProducer.EmitReview(ctx, flag); err != nil {
				p.log.Warn("review emit failed for unsupported format",
					"event_id", event.EventID,
					"format", event.SourceFormat,
				)
			}
		}()
		return nil
	}
}

// processFHIRR4 parses a FHIR R4 bundle and writes one CDR row per entry.
func (p *Pipeline) processFHIRR4(ctx context.Context, event *kafka.RawClinicalEvent, raw []byte, sourceHash string) error {
	obs, conds, meds, allergies, err := ParseFHIRR4Bundle(raw)
	if err != nil {
		return fmt.Errorf("parse FHIR R4: %w", err)
	}

	writeWithReview := func(comp *cdr.Composition, flag *lookup.ReviewFlag) error {
		if flag != nil {
			go func() {
				if err := p.reviewProducer.EmitReview(context.Background(), *flag); err != nil {
					p.log.Warn("review emit failed",
						"event_id", event.EventID,
						"code", flag.UnknownCode,
					)
				}
			}()
		}
		return p.writer.Write(ctx, event.UserHash, event.DocHash, comp)
	}

	for i := range obs {
		comp, flag := BuildObservationComposition(&obs[i], event.EventID, event.UserHash, event.DocHash, sourceHash)
		if err := writeWithReview(comp, flag); err != nil {
			return fmt.Errorf("write observation %d: %w", i, err)
		}
	}

	for i := range conds {
		comp, flags := BuildConditionComposition(&conds[i], event.EventID, event.UserHash, event.DocHash, sourceHash)
		for _, f := range flags {
			if f != nil {
				go func(fl lookup.ReviewFlag) {
					_ = p.reviewProducer.EmitReview(context.Background(), fl)
				}(*f)
			}
		}
		if err := p.writer.Write(ctx, event.UserHash, event.DocHash, comp); err != nil {
			return fmt.Errorf("write condition %d: %w", i, err)
		}
	}

	for i := range meds {
		comp, flag := BuildMedicationComposition(&meds[i], event.EventID, event.UserHash, event.DocHash, sourceHash)
		if err := writeWithReview(comp, flag); err != nil {
			return fmt.Errorf("write medication %d: %w", i, err)
		}
	}

	for i := range allergies {
		comp, flag := BuildAllergyComposition(&allergies[i], event.EventID, event.UserHash, event.DocHash, sourceHash)
		if err := writeWithReview(comp, flag); err != nil {
			return fmt.Errorf("write allergy %d: %w", i, err)
		}
	}

	return nil
}

// validateHashes checks that both userHash and docHash are 64 lowercase hex chars.
// Per-project standard: SHA3-256 outputs 64 lowercase hex characters.
func validateHashes(userHash, docHash string) error {
	if len(userHash) != 64 {
		return fmt.Errorf("user_hash length %d (want 64)", len(userHash))
	}
	if len(docHash) != 64 {
		return fmt.Errorf("doc_hash length %d (want 64)", len(docHash))
	}
	if _, err := hex.DecodeString(userHash); err != nil {
		return fmt.Errorf("user_hash not valid hex: %w", err)
	}
	if _, err := hex.DecodeString(docHash); err != nil {
		return fmt.Errorf("doc_hash not valid hex: %w", err)
	}
	return nil
}

func zeroSlice(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

func sha3HexString(input []byte) string {
	h := sha3.New256()
	h.Write(input)
	return hex.EncodeToString(h.Sum(nil))
}
