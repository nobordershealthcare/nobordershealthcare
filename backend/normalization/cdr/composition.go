// Package cdr provides the ScyllaDB Clinical Data Repository client,
// schema types, and FHIR-oriented query helpers.
package cdr

import (
	"context"
	"time"
)

// CompositionVersion is bumped whenever the Composition JSON schema changes.
// The reader uses this to apply the correct deserialization path.
const CompositionVersion = 1

// CompositionType enumerates the FHIR resource types stored in the CDR.
type CompositionType string

const (
	TypeObservation        CompositionType = "observation"
	TypeCondition          CompositionType = "condition"
	TypeMedicationStatement CompositionType = "medication_statement"
	TypeAllergyIntolerance CompositionType = "allergy_intolerance"
)

// Composition is the internal openEHR-inspired normalized clinical record.
// It is serialised to JSON and encrypted with AES-256-GCM before storage.
// No patient identifiers appear here — only codes and values.
type Composition struct {
	Version int    `json:"v"`    // CompositionVersion — for migration
	Type    string `json:"type"` // one of the TypeXxx constants above

	// ── Code fields (at most one per composition) ─────────────────────────
	LOINCCode  string `json:"loinc,omitempty"`  // e.g. "4548-4"
	ATCCode    string `json:"atc,omitempty"`    // e.g. "A10BA02"
	ICD10Code  string `json:"icd10,omitempty"`  // e.g. "E11.9"
	SNOMEDCode string `json:"snomed,omitempty"` // e.g. "764146007"

	// ── Observation-specific ──────────────────────────────────────────────
	ValueNum *float64 `json:"val_num,omitempty"` // numeric measurement
	ValueStr string   `json:"val_str,omitempty"` // coded/string result
	Unit     string   `json:"unit,omitempty"`    // UCUM unit string

	// ── Common clinical status ────────────────────────────────────────────
	// Observation: "final" | "preliminary"
	// Condition:   "active" | "resolved" | "inactive"
	// Medication:  "active" | "stopped" | "unknown"
	// Allergy:     "active" | "resolved"
	Status string `json:"status"`

	// ── UNKNOWN flag ──────────────────────────────────────────────────────
	// Set to true when any code in this composition resolved to UnknownCode.
	// A ReviewFlag has already been published to the review Kafka topic.
	ReviewRequired bool `json:"review,omitempty"`

	// ── Audit linkage ─────────────────────────────────────────────────────
	SourceHash string    `json:"src_hash"`    // SHA3-256(Kafka EventID)
	RecordedAt time.Time `json:"recorded_at"` // when the source event was received
}

// KeyFetcher retrieves the per-patient AES-256 key (32 bytes) from Vault.
// The caller must zero the returned slice after use.
// The userHash argument is the SHA3-256(userID) — 64 lowercase hex chars.
type KeyFetcher func(ctx context.Context, userHash string) ([]byte, error)

// Row is the flat ScyllaDB representation used in queries.
// It carries the userHash + docHash pair alongside the blob so readers
// can decrypt without a second lookup.
type Row struct {
	UserHash        string
	DocHash         string
	CompositionType string
	LOINCCode       string
	ATCCode         string
	ICD10Code       string
	SNOMEDCode      string
	SourceHash      string
	EncryptedBlob   []byte
	SchemaVersion   int16
	ReviewRequired  bool
	CreatedAt       time.Time
}
