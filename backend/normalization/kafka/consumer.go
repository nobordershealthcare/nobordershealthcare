package kafka

import (
	"context"
	"fmt"
	"time"

	"github.com/segmentio/kafka-go"
)

const (
	// ConsumerGroupNormalization is the consumer group ID for the normalization
	// pipeline. Offsets are committed only after a successful CDR write so that
	// a pod crash causes the event to be reprocessed, not silently dropped.
	ConsumerGroupNormalization = "normalization-consumer"
)

// Consumer reads RawClinicalEvents from the WORM staging topic.
// Offsets are committed manually (CommitInterval: 0) — never auto-committed.
// This ensures exactly-once normalization: a failure before CDR write causes
// the message to be re-delivered after pod restart.
type Consumer struct {
	r *kafka.Reader
}

// NewConsumer creates a consumer in the normalization consumer group.
// StartOffset: FirstOffset guarantees a new consumer group processes the
// entire topic history — important for disaster recovery re-normalization.
func NewConsumer(brokers []string) *Consumer {
	return &Consumer{
		r: kafka.NewReader(kafka.ReaderConfig{
			Brokers:        brokers,
			Topic:          TopicRaw,
			GroupID:        ConsumerGroupNormalization,
			MinBytes:       1,
			MaxBytes:       10 << 20, // 10 MiB per fetch
			MaxWait:        500 * time.Millisecond,
			StartOffset:    kafka.FirstOffset, // read from beginning for new group
			CommitInterval: 0,                 // manual commit only — never auto
		}),
	}
}

// FetchMessage returns the next unprocessed message.
// Blocks until a message is available or ctx is cancelled.
// The caller MUST call CommitMessage after a successful CDR write.
func (c *Consumer) FetchMessage(ctx context.Context) (kafka.Message, error) {
	return c.r.FetchMessage(ctx)
}

// CommitMessage acknowledges successful processing of msg.
// Only call this after the CDR write has been confirmed.
func (c *Consumer) CommitMessage(ctx context.Context, msg kafka.Message) error {
	if err := c.r.CommitMessages(ctx, msg); err != nil {
		return fmt.Errorf("consumer commit offset %d: %w", msg.Offset, err)
	}
	return nil
}

// Decode parses the raw event from a Kafka message value.
func (c *Consumer) Decode(msg kafka.Message) (*RawClinicalEvent, error) {
	event, err := DecodeRawClinicalEvent(msg.Value)
	if err != nil {
		return nil, fmt.Errorf("consumer decode partition=%d offset=%d: %w",
			msg.Partition, msg.Offset, err)
	}
	return event, nil
}

// Close releases the reader and its underlying connections.
func (c *Consumer) Close() error {
	return c.r.Close()
}
