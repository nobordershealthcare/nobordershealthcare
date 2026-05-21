package main

// AccessRecord is stored in world state under composite key ACCESS~userHash~docHash~role.
// Every field is a SHA3-256 hex string or a primitive — no PII is ever stored.
type AccessRecord struct {
	UserHash  string `json:"userHash"`
	DocHash   string `json:"docHash"`
	Role      string `json:"role"`
	GrantedBy string `json:"grantedBy"` // SHA3-256 of granting identity cert DER bytes
	Expiry    int64  `json:"expiry"`    // Unix seconds; 0 = perpetual
	Revoked   bool   `json:"revoked"`
}

// AuditEntry is stored under composite key AUDIT~docHash~txID.
// Admin1Hash, Admin2Hash, OldRole, NewRole are populated only for admin operations.
type AuditEntry struct {
	DocHash    string `json:"docHash"`
	ActorHash  string `json:"actorHash"`
	Role       string `json:"role"`
	Operation  string `json:"operation"`
	TxID       string `json:"txID"`
	Timestamp  int64  `json:"timestamp"`
	Admin1Hash string `json:"admin1Hash,omitempty"`
	Admin2Hash string `json:"admin2Hash,omitempty"`
	OldRole    string `json:"oldRole,omitempty"`
	NewRole    string `json:"newRole,omitempty"`
}
