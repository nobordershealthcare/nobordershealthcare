package kafka

import (
	"context"
	"fmt"
	"strconv"
	"time"

	"github.com/segmentio/kafka-go"
)

const (
	// TopicRaw is the WORM staging topic. All raw events land here before
	// normalization. Retention is 7 years (set at broker level).
	// Application code never deletes from this topic.
	TopicRaw = "clinical-events-raw"
)

// Producer writes RawClinicalEvents to the WORM staging topic.
// It must be closed via Close() on service shutdown.
type Producer struct {
	w *kafka.Writer
}

// NewProducer creates a producer connected to the given brokers.
// Uses key-based partitioning (Hash balancer) so all events for a given
// userHash+docHash pair land on the same partition in order.
func NewProducer(brokers []string) *Producer {
	return &Producer{
		w: &kafka.Writer{
			Addr:         kafka.TCP(brokers...),
			Topic:        TopicRaw,
			Balancer:     &kafka.Hash{}, // deterministic partition by message key
			RequiredAcks: kafka.RequireAll, // acks=all: all ISR replicas must confirm
			Compression:  kafka.Lz4,
			WriteTimeout: 5 * time.Second,
			ReadTimeout:  5 * time.Second,
			MaxAttempts:  3,
			// BatchTimeout: small to minimise staging latency before normalization
			BatchTimeout: 10 * time.Millisecond,
		},
	}
}

// Stage writes a raw clinical event to the WORM Kafka topic.
// This MUST succeed before any normalization or CDR write occurs.
// If Stage returns an error, the caller must abort the request with 503 —
// an unstaged event has no audit record and must not proceed downstream.
func (p *Producer) Stage(ctx context.Context, event *RawClinicalEvent) error {
	payload, err := event.Encode()
	if err != nil {
		return fmt.Errorf("producer stage encode: %w", err)
	}

	msg := kafka.Message{
		Key:   []byte(MessageKey(event.UserHash, event.DocHash)),
		Value: payload,
		Time:  time.Now(),
		Headers: []kafka.Header{
			{Key: "schema_version", Value: []byte(strconv.Itoa(int(event.SchemaVersion)))},
			{Key: "source_format", Value: []byte(event.SourceFormat)},
			{Key: "event_id", Value: []byte(event.EventID)},
		},
	}

	if err := p.w.WriteMessages(ctx, msg); err != nil {
		return fmt.Errorf("producer stage write: %w", err)
	}
	return nil
}

// Close flushes pending writes and releases the underlying connection.
func (p *Producer) Close() error {
	return p.w.Close()
}
