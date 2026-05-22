package main

// SignatureRecord is stored in world state under composite key SIG~{documentHash}.
// All fields are hashes, base64url strings, or primitive values — no PII is ever stored.
// A document may only have one canonical signature record; re-signing creates a new
// document hash and a new record.
type SignatureRecord struct {
	DocumentHash       string   `json:"documentHash"`       // SHA3-256 hex of signed document bytes
	SignerPubKeyHash   string   `json:"signerPubKeyHash"`   // SHA3-256 hex of signer's Ed25519 public key DER
	Signature          string   `json:"signature"`          // base64url(Ed25519 raw 64-byte signature)
	IdentityProvider   string   `json:"identityProvider"`   // "bankid-se" | "bankid-no" | "eid-pt" | ...
	IdentityVerifiedAt int64    `json:"identityVerifiedAt"` // Unix seconds — when step-up auth completed
	LegalBasis         []string `json:"legalBasis"`         // GDPR Art. refs: ["Art.6(1)(a)", "Art.9(2)(a)"]
	DocumentType       string   `json:"documentType"`       // "consent"|"healthcare_proxy"|"dpa"|"ehr_access"
	Jurisdictions      []string `json:"jurisdictions"`      // ISO 3166-1 alpha-2: ["SE", "PT", "DE"]
	RecordedAt         int64    `json:"recordedAt"`         // Fabric GetTxTimestamp — NEVER time.Now()
	TxID               string   `json:"txID"`               // Fabric transaction ID
}

// validIdentityProviders enumerates recognised eID schemes. Extend as integrations are added.
var validIdentityProviders = map[string]bool{
	"bankid-se": true,
	"bankid-no": true,
	"bankid-dk": true,
	"bankid-fi": true,
	"eid-pt":    true,
	"eid-de":    true,
	"eid-fr":    true,
}

// validDocumentTypes enumerates document categories stored in the legal vault.
var validDocumentTypes = map[string]bool{
	"consent":           true,
	"healthcare_proxy":  true,
	"dpa":               true,
	"ehr_access":        true,
}
