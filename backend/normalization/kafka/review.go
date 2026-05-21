package kafka

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/segmentio/kafka-go"

	"github.com/nobordershealthcare/normalization/lookup"
)

const (
	// TopicReview receives ReviewFlag events for unrecognised clinical codes.
	// Human reviewers consume this topic and submit corrections as new
	// RawClinicalEvents — the pipeline is append-only, never mutated.
	TopicReview = "clinical-codes-review"
)

// ReviewProducer publishes lookup.ReviewFlag values to the review topic.
// Emitting a review flag never blocks the normalization pipeline —
// the composition is stored with ReviewRequired=true and the flag is sent
// asynchronously so a review topic outage does not halt ingestion.
type ReviewProducer struct {
	w *kafka.Writer
}

// NewReviewProducer creates a producer for the clinical-codes-review topic.
func NewReviewProducer(brokers []string) *ReviewProducer {
	return &ReviewProducer{
		w: &kafka.Writer{
			Addr:         kafka.TCP(brokers...),
			Topic:        TopicReview,
			Balancer:     &kafka.Hash{},
			RequiredAcks: kafka.RequireAll,
			WriteTimeout: 5 * time.Second,
		},
	}
}

// EmitReview publishes a ReviewFlag for a single unrecognised code.
// Call from a goroutine when you do not want to block the caller:
//
//	go func() { _ = reviewProducer.EmitReview(context.Background(), flag) }()
func (r *ReviewProducer) EmitReview(ctx context.Context, flag lookup.ReviewFlag) error {
	payload, err := json.Marshal(flag)
	if err != nil {
		return fmt.Errorf("marshal review flag: %w", err)
	}
	return r.w.WriteMessages(ctx, kafka.Message{
		Key:   []byte(MessageKey(flag.UserHash, flag.DocHash)),
		Value: payload,
		Time:  time.Now(),
		Headers: []kafka.Header{
			{Key: "code_system", Value: []byte(flag.CodeSystem)},
			{Key: "event_id", Value: []byte(flag.EventID)},
		},
	})
}

// Close flushes pending writes and releases the underlying connection.
func (r *ReviewProducer) Close() error {
	return r.w.Close()
}
