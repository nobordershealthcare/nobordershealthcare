package main

// ConsentAuditRecord is stored in world state under composite key CONSENT~{userIdHash}~{txID}.
// Both grant and revocation events are separate records — the ledger is append-only.
// Query by userIdHash partial key to reconstruct the full consent lifecycle (GDPR Art.15).
type ConsentAuditRecord struct {
	UserIdHash      string `json:"userIdHash"`      // SHA3-256(salt+userID) — no PII
	ConsentType     string `json:"consentType"`     // enum: see validConsentTypes
	Event           string `json:"event"`           // "granted" | "revoked"
	ExpiresAt       int64  `json:"expiresAt"`       // Unix seconds; 0 = indefinite
	SignatureTxHash string `json:"signatureTxHash"` // channel-1 txID of the AdES signature
	RecordedAt      int64  `json:"recordedAt"`      // Fabric GetTxTimestamp
	TxID            string `json:"txID"`            // Fabric transaction ID
}

// validConsentTypes enumerates the consent categories the patient may grant.
var validConsentTypes = map[string]bool{
	"ehr_access":  true, // general access to eHR records
	"research":    true, // anonymised aggregate research
	"insurance":   true, // claim-relevant data sharing with insurer
	"emergency":   true, // emergency QR scope (always limited to IPS subset)
	"telemedicine": true, // video/SIP session with a clinician
}
