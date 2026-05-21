// Package lookup provides deterministic, static lookup tables for all clinical
// coding systems used in the normalization pipeline.
//
// CRITICAL: No generative AI may be used to infer or guess codes.
// If a code is not present in these tables, return UnknownCode and emit
// a ReviewFlag. Never guess. Never infer. Never call an external API.
package lookup

// LOINCCode is a LOINC observation identifier (e.g. "4548-4" for HbA1c).
type LOINCCode string

// ATCCode is an Anatomical Therapeutic Chemical classification code
// (e.g. "A10BA02" for Metformin). ATC is mandatory for EU-facing code.
// RxNorm is forbidden in this codebase.
type ATCCode string

// SNOMEDCode is a SNOMED CT concept identifier (e.g. "764146007" for Penicillin).
type SNOMEDCode string

// ICD10Code is an ICD-10-CM/GM diagnosis code (e.g. "E11.9" for T2DM).
type ICD10Code string

// UnknownCode is returned when an incoming code is not found in any lookup table.
// It is a valid pipeline output — never an error. The accompanying ReviewFlag
// triggers human review via the clinical-codes-review Kafka topic.
const UnknownCode = "UNKNOWN"

// CodeSystem identifies which clinical coding standard an unknown code belongs to.
type CodeSystem string

const (
	CodeSystemATC    CodeSystem = "ATC"
	CodeSystemLOINC  CodeSystem = "LOINC"
	CodeSystemSNOMED CodeSystem = "SNOMED"
	CodeSystemICD10  CodeSystem = "ICD10"
)

// ReviewFlag is published to the clinical-codes-review Kafka topic whenever
// an unrecognized code is encountered. Contains no PII — only hashes.
type ReviewFlag struct {
	EventID     string     `json:"event_id"`    // UUID v4 from the originating RawClinicalEvent
	UserHash    string     `json:"user_hash"`   // SHA3-256(userID), 64 lowercase hex chars
	DocHash     string     `json:"doc_hash"`    // SHA3-256(docID),  64 lowercase hex chars
	UnknownCode string     `json:"unknown_code"`
	CodeSystem  CodeSystem `json:"code_system"`
}
