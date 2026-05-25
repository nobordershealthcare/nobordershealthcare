package main

// MilitaryAccessRecord is stored under composite key MIL~patientHash~txID.
// Every field is a SHA3-256 hex string, a string enum, or a primitive.
// No PII, no health data, no clearance, no unit, no rank, no coordinates.
type MilitaryAccessRecord struct {
	PatientHash      string   `json:"patientHash"`      // SHA3-256(serviceNumber)
	AccessorHash     string   `json:"accessorHash"`     // SHA3-256(medic_id or dvi_team_id)
	AccessorType     string   `json:"accessorType"`     // "medevac_medic" | "dvi_team" | "nok_notifier"
	AccessScope      []string `json:"accessScope"`      // ["blood_type","allergies","nok"] etc.
	LocationHash     string   `json:"locationHash"`     // SHA3-256(grid_coords) — never plaintext
	RecordedAt       int64    `json:"recordedAt"`       // Fabric tx timestamp (GetTxTimestamp)
	TxID             string   `json:"txID"`             // Fabric transaction ID
}

// ForensicAccessRecord is stored under composite key FORENSIC~patientHash~txID.
// Higher-stakes access — 2-of-2 endorsement required.
type ForensicAccessRecord struct {
	PatientHash  string   `json:"patientHash"`  // SHA3-256(serviceNumber)
	DVITeamHash  string   `json:"dviTeamHash"`  // SHA3-256(dvi_team_id)
	AccessScope  []string `json:"accessScope"`  // ["dna_reference","identifying_marks"]
	RecordedAt   int64    `json:"recordedAt"`   // Fabric tx timestamp
	TxID         string   `json:"txID"`
}

// NOKNotificationRecord is stored under composite key NOK~patientHash~txID.
type NOKNotificationRecord struct {
	PatientHash      string `json:"patientHash"`      // SHA3-256(serviceNumber)
	NOKHash          string `json:"nokHash"`          // SHA3-256(nok_phone)
	NotificationType string `json:"notificationType"` // "injured" | "kia" | "missing"
	RecordedAt       int64  `json:"recordedAt"`
	TxID             string `json:"txID"`
}

// MilitaryProfileRecord is stored under composite key MILPROFILE~serviceNumberHash.
// Registered once during profile activation.
type MilitaryProfileRecord struct {
	ServiceNumberHash string `json:"serviceNumberHash"` // SHA3-256(serviceNumber)
	NationalityCode   string `json:"nationalityCode"`   // ISO 3166-1 alpha-2
	DNAReferenceHash  string `json:"dnaReferenceHash"`  // SHA3-256(dnaRefNumber)
	ProfileType       string `json:"profileType"`       // "military" | "firstResponder"
	RegisteredAt      int64  `json:"registeredAt"`
	TxID              string `json:"txID"`
}

// BulkBatchRecord logs a battalion-level import event under BULK~tenantHash~batchReference.
type BulkBatchRecord struct {
	TenantHash     string   `json:"tenantHash"`     // SHA3-256(unit_admin_id)
	BatchReference string   `json:"batchReference"` // import batch ID
	ProfileHashes  []string `json:"profileHashes"`  // []SHA3-256(serviceNumber)
	Count          int      `json:"count"`
	RecordedAt     int64    `json:"recordedAt"`
	TxID           string   `json:"txID"`
}

// validProfileTypes are the accepted values for profileType in RegisterMilitaryProfile.
var validProfileTypes = map[string]bool{
	"military":      true,
	"firstResponder": true,
}

// validNATONationalities is a representative set; extend as needed.
// Full ISO 3166-1 alpha-2 list is validated by length check only in production.
// Here we enforce 2-char constraint.
func isValidISO3166Alpha2(code string) bool {
	return len(code) == 2
}
