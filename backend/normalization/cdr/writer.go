package cdr

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/gocql/gocql"

	"github.com/nobordershealthcare/normalization/encryption"
)

// Writer writes normalized Compositions to all three CDR tables atomically
// using a ScyllaDB logged batch.
type Writer struct {
	session    *gocql.Session
	keyFetcher KeyFetcher
}

// NewWriter creates a Writer backed by the given session and key fetcher.
func NewWriter(session *gocql.Session, kf KeyFetcher) *Writer {
	return &Writer{session: session, keyFetcher: kf}
}

// Write encrypts the Composition and inserts it into all three CDR tables
// in a single logged batch. If any insert fails the entire batch is rolled back.
//
// userHash and docHash must be 64 lowercase hex SHA3-256 values — the caller
// is responsible for validating them before calling Write.
func (w *Writer) Write(ctx context.Context, userHash, docHash string, comp *Composition) error {
	// Fetch per-patient AES-256 key from Vault.
	key, err := w.keyFetcher(ctx, userHash)
	if err != nil {
		return fmt.Errorf("cdr write: key fetch for user %s: %w", userHash[:8]+"...", err)
	}
	defer zeroBytes(key)

	// Serialise then encrypt the Composition.
	plain, err := json.Marshal(comp)
	if err != nil {
		return fmt.Errorf("cdr write: marshal composition: %w", err)
	}
	blob, err := encryption.Encrypt(key, plain)
	if err != nil {
		return fmt.Errorf("cdr write: encrypt composition: %w", err)
	}
	// Zero plaintext immediately after encryption.
	zeroBytes(plain)

	now := time.Now().UTC()
	sv := int16(CompositionVersion)

	batch := w.session.NewBatch(gocql.LoggedBatch)

	// ── Table 1: cdr.compositions ─────────────────────────────────────────
	batch.Query(
		`INSERT INTO cdr.compositions
		 (user_hash, doc_hash, composition_type, loinc_code, atc_code,
		  icd10_code, snomed_code, source_hash, encrypted_blob,
		  schema_version, review_required, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userHash, docHash, comp.Type,
		nullableStr(comp.LOINCCode), nullableStr(comp.ATCCode),
		nullableStr(comp.ICD10Code), nullableStr(comp.SNOMEDCode),
		comp.SourceHash, blob, sv, comp.ReviewRequired, now,
	)

	// ── Table 2: cdr.compositions_by_type ────────────────────────────────
	batch.Query(
		`INSERT INTO cdr.compositions_by_type
		 (user_hash, composition_type, doc_hash, loinc_code, atc_code,
		  icd10_code, snomed_code, source_hash, encrypted_blob,
		  schema_version, review_required, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userHash, comp.Type, docHash,
		nullableStr(comp.LOINCCode), nullableStr(comp.ATCCode),
		nullableStr(comp.ICD10Code), nullableStr(comp.SNOMEDCode),
		comp.SourceHash, blob, sv, comp.ReviewRequired, now,
	)

	// ── Table 3: cdr.observations_by_loinc (only for observations) ───────
	if comp.Type == string(TypeObservation) && comp.LOINCCode != "" {
		batch.Query(
			`INSERT INTO cdr.observations_by_loinc
			 (user_hash, loinc_code, doc_hash, source_hash, encrypted_blob,
			  schema_version, review_required, created_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			userHash, comp.LOINCCode, docHash,
			comp.SourceHash, blob, sv, comp.ReviewRequired, now,
		)
	}

	if err := w.session.ExecuteBatch(batch); err != nil {
		return fmt.Errorf("cdr write: execute batch user=%s doc=%s: %w",
			userHash[:8]+"...", docHash[:8]+"...", err)
	}
	return nil
}

// nullableStr returns nil if s is empty so Scylla stores a true CQL null
// rather than an empty string — prevents spurious index entries.
func nullableStr(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

func zeroBytes(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
