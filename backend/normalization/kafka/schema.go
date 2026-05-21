// Package kafka provides WORM (write-once, read-many) Kafka producers and
// consumers for the normalization pipeline.
//
// Topic "clinical-events-raw" receives encrypted raw clinical events BEFORE
// any normalization. It is the audit record of record — nothing is ever
// deleted from it. Retention is set at the broker to 7 years per EU MDR.
//
// No PII may appear in any field of RawClinicalEvent or in Kafka message keys.
package kafka

import (
	"encoding/json"
	"fmt"
)

// SchemaVersion is bumped whenever RawClinicalEvent fields change.
// Consumers use this to apply the correct deserialization path.
const SchemaVersion int32 = 1

// RawClinicalEvent is the envelope written to the WORM Kafka topic before
// any normalization. EncryptedBlob holds the AES-256-GCM ciphertext
// (12-byte nonce prepended). No PII may appear in any field.
type RawClinicalEvent struct {
	EventID       string `json:"event_id"`       // UUID v4 — idempotency key
	UserHash      string `json:"user_hash"`      // SHA3-256(userID), 64 lowercase hex chars
	DocHash       string `json:"doc_hash"`       // SHA3-256(docID),  64 lowercase hex chars
	SourceFormat  string `json:"source_format"`  // "hl7v2" | "cda_r2" | "fhir_r4" | "pdf"
	EncryptedBlob []byte `json:"encrypted_blob"` // AES-256-GCM; nonce prepended (12 bytes + ciphertext)
	ReceivedAt    int64  `json:"received_at"`    // Unix nanoseconds
	SchemaVersion int32  `json:"schema_version"`
}

// Encode serialises the event to JSON. The encrypted blob is already opaque;
// no additional encoding layer is needed.
func (e *RawClinicalEvent) Encode() ([]byte, error) {
	b, err := json.Marshal(e)
	if err != nil {
		return nil, fmt.Errorf("encode RawClinicalEvent: %w", err)
	}
	return b, nil
}

// DecodeRawClinicalEvent deserialises a Kafka message value.
func DecodeRawClinicalEvent(b []byte) (*RawClinicalEvent, error) {
	var e RawClinicalEvent
	if err := json.Unmarshal(b, &e); err != nil {
		return nil, fmt.Errorf("decode RawClinicalEvent: %w", err)
	}
	return &e, nil
}

// MessageKey builds the deterministic Kafka message key.
// Format: SHA3-256(userID) + ":" + SHA3-256(docID).
// Key-based partitioning guarantees ordering for all events of a single document.
// No PII is embedded.
func MessageKey(userHash, docHash string) string {
	return userHash + ":" + docHash
}
