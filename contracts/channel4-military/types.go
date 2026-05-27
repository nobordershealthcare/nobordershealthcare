package main

// MilitaryAccessRecord is stored under composite key MIL~patientHash~txID.
// Every field is a SHA3-256 hex string, a string enum, or a primitive.
// Fields never stored: PII, health data, clearance, unit designation, rank, or coords.
type MilitaryAccessRecord struct {
	PatientHash  string   `json:"patient_hash"`
	AccessorHash string   `json:"accessor_hash"` // SHA3-256(medic_id)
	AccessorType string   `json:"accessor_type"` // "medic"|"dvi_team"|"command"|"admin"
	Authority    string   `json:"authority"`     // AuthorityType: "ua_mo"|"eu_gendarmerie"|"nato"|...
	AccessScope  []string `json:"access_scope"`
	LocationHash string   `json:"location_hash"` // SHA3-256(grid_coords) — never plaintext coords
	Timestamp    string   `json:"timestamp"`     // GetTxTimestamp() — deterministic in Fabric
	CrossBorder  bool     `json:"cross_border"`  // true if access in different country than registration
	TxID         string   `json:"tx_id"`
}

// ForensicAccessRecord is stored under composite key FORENSIC~patientHash~txID.
// Higher-stakes access — 2-of-2 endorsement required.
type ForensicAccessRecord struct {
	PatientHash   string   `json:"patient_hash"`
	DVITeamHash   string   `json:"dvi_team_hash"`            // SHA3-256(team_id) — never team name
	Authority     string   `json:"authority"`
	AccessScope   []string `json:"access_scope"`             // ["dna_reference","identifying_marks","dental_ref"]
	EUCPReference string   `json:"eucp_reference,omitempty"` // UCPM coordination reference
	Timestamp     string   `json:"timestamp"`
	TxID          string   `json:"tx_id"`
}

// NOKNotificationRecord is stored under composite key NOK~patientHash~txID.
type NOKNotificationRecord struct {
	PatientHash      string `json:"patient_hash"`
	NOKHash          string `json:"nok_hash"`          // SHA3-256(nok_phone) — never plaintext
	NotificationType string `json:"notification_type"` // "injured"|"kia"|"missing"|"found"
	RoutingPath      string `json:"routing_path"`      // "direct"|"via_duty_officer"|"via_europol_siena"
	Authority        string `json:"authority"`
	Timestamp        string `json:"timestamp"`
	TxID             string `json:"tx_id"`
}

// MilitaryProfileRecord is stored under composite key MILPROFILE~serviceNumberHash.
type MilitaryProfileRecord struct {
	ServiceNumberHash string `json:"service_number_hash"` // SHA3-256(serviceNumber)
	NationalityCode   string `json:"nationality_code"`    // ISO 3166-1 alpha-2
	DNAReferenceHash  string `json:"dna_reference_hash"`  // SHA3-256(dnaRefNumber)
	OperationalRole   string `json:"operational_role"`    // OperationalRole value
	Authority         string `json:"authority"`           // AuthorityType value
	LegalBasis        string `json:"legal_basis"`         // LegalBasisType value
	RegisteredAt      string `json:"registered_at"`
	TxID              string `json:"tx_id"`
}

// BulkRegistrationRecord logs a battalion/corporate/family import event under BULK~tenantHash~batchRef.
type BulkRegistrationRecord struct {
	TenantHash        string   `json:"tenant_hash"`         // SHA3-256(unit_admin_id)
	ProfileHashes     []string `json:"profile_hashes"`      // []SHA3-256(service_number)
	Authority         string   `json:"authority"`           // AuthorityType value
	BatchReference    string   `json:"batch_reference"`     // SHA3-256(admin_id + timestamp)
	ProposerAdminHash string   `json:"proposer_admin_hash"` // SHA3-256(proposing admin ID) — must differ from approver
	ApproverAdminHash string   `json:"approver_admin_hash"` // SHA3-256(approving admin ID) — must differ from proposer
	ProfileCount      int      `json:"profile_count"`
	Timestamp         string   `json:"timestamp"`
	TxID              string   `json:"tx_id"`
}

// validAuthorities is the set of accepted AuthorityType values.
var validAuthorities = map[string]bool{
	"ua_mo": true, "ua_mvs": true, "ua_sbu": true, "ua_dsns": true, "ua_civilian": true,
	"eu_police": true, "eu_gendarmerie": true, "eu_special": true,
	"eu_civil": true, "eu_border": true, "eu_interpol": true,
	"nato": true, "interpol": true,
}

// validLegalBases is the set of accepted LegalBasisType values.
var validLegalBases = map[string]bool{
	"gdpr_art9": true, "led_art10": true, "nato_stanag": true, "vital_interests": true,
}

// validOperationalRoles is the set of accepted OperationalRole values.
var validOperationalRoles = map[string]bool{
	"none": true, "lawEnforcement": true, "specialOps": true,
	"nationalGuard": true, "gendarmerie": true, "civilDefense": true,
	"fireRescue": true, "sarTeam": true, "euBorderGuard": true, "europolOfficer": true,
}

// validProfileTypes are the accepted values for profileType in RegisterMilitaryProfile.
var validProfileTypes = map[string]bool{
	"military":      true,
	"firstResponder": true,
}

func isValidISO3166Alpha2(code string) bool {
	return len(code) == 2
}
