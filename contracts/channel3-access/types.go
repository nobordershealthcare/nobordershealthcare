package main

// AccessAuditRecord is stored in world state under composite key ACCESS~{patientIdHash}~{txID}.
// Each record captures a single eHR data access event — i.e. when a clinician or system
// actually READ patient data, as opposed to when they were GRANTED permission (access control).
// GDPR Art.15 requires the patient to be able to retrieve this history on demand.
type AccessAuditRecord struct {
	PatientIdHash  string   `json:"patientIdHash"`  // SHA3-256(salt+patientID) — no PII
	AccessorIdHash string   `json:"accessorIdHash"` // SHA3-256(salt+accessorID) — no PII
	AccessorType   string   `json:"accessorType"`   // enum: see validAccessorTypes
	LicenseHash    string   `json:"licenseHash"`    // SHA3-256 of accessor's professional licence DER
	AccessScope    []string `json:"accessScope"`    // FHIR resource types read, e.g. ["Observation","Condition"]
	Duration       int32    `json:"duration"`       // Seconds the record was held open (anonymised timing)
	ConsentRef     string   `json:"consentRef"`     // channel-2 txID of governing consent record
	SignatureRef   string   `json:"signatureRef"`   // channel-1 txID of accessor's session AdES signature
	RecordedAt     int64    `json:"recordedAt"`     // Fabric GetTxTimestamp — NEVER time.Now()
	TxID           string   `json:"txID"`           // Fabric transaction ID
}

// validAccessorTypes enumerates the roles that may access patient eHR data.
var validAccessorTypes = map[string]bool{
	"er_doctor":   true,
	"gp":          true,
	"specialist":  true,
	"nurse":       true,
	"insurer":     true,
	"researcher":  true,
	"guardian":    true,
	"admin":       true,
}

// validFHIRResources enumerates FHIR R4 resource types allowed in accessScope.
var validFHIRResources = map[string]bool{
	"Observation":         true,
	"Condition":           true,
	"MedicationStatement": true,
	"AllergyIntolerance":  true,
	"Composition":         true, // IPS document
	"Patient":             true,
	"Immunization":        true,
	"Procedure":           true,
	"DiagnosticReport":    true,
}
