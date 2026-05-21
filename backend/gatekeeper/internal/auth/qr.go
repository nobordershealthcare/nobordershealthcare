package auth

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// QRScopeToken is the payload embedded in an emergency QR code.
// The patient signs this with their Ed25519 key stored in the Secure Enclave.
// Fields are minimal by design — no PII, only hashes and scope.
type QRScopeToken struct {
	// HashedPatientID is SHA3-256(salt+patientID) — 64 lowercase hex chars.
	HashedPatientID string `json:"sub"`
	// Scope lists the clinical record categories the bearer may access.
	// Values are constrained to the IPS emergency subset.
	Scope []string `json:"scope"`
	// IssuedAt is UTC Unix seconds. The token is valid for TokenTTL from this time.
	IssuedAt int64 `json:"iat"`
	// Sig is the base64url-encoded Ed25519 signature over the canonical JSON of
	// the unsigned fields (sub, scope, iat). Computed by the iOS wallet.
	Sig string `json:"sig"`
}

const (
	// QRTokenTTL is the maximum age of a QR scope token.
	// Kept short to limit exposure of a stolen QR code in emergency scenarios.
	QRTokenTTL = 10 * time.Minute

	// IPSRole is the role granted to the bearer of a valid QR token.
	IPSRole = "er_doctor"
)

// allowedIPSScopes is the closed set of scopes an emergency QR token may grant.
// A token claiming any scope outside this set is rejected.
var allowedIPSScopes = map[string]bool{
	"allergies":   true,
	"medications": true,
	"diagnoses":   true,
	"blood_type":  true,
	"conditions":  true,
}

// QRVerifier validates patient-signed emergency QR scope tokens.
type QRVerifier struct {
	// getPatientPubKey retrieves the Ed25519 public key registered to the given
	// hashed patient ID. The key is stored in ScyllaDB (encrypted) and looked up
	// without touching any plaintext identifier.
	getPatientPubKey func(hashedPatientID string) (ed25519.PublicKey, error)
}

func NewQRVerifier(getPubKey func(string) (ed25519.PublicKey, error)) *QRVerifier {
	return &QRVerifier{getPatientPubKey: getPubKey}
}

// Verify validates a raw QR token JSON payload and returns the verified scope.
// Returns the hashed patient ID and scope list on success.
//
// Checks performed (all must pass):
//  1. JSON unmarshalling and field presence
//  2. HashedPatientID is a valid 64-char lowercase hex string
//  3. Scope is non-empty and every entry is in allowedIPSScopes
//  4. Token is within QRTokenTTL of IssuedAt (not expired, not future-dated)
//  5. Ed25519 signature over canonical payload verifies against patient public key
func (v *QRVerifier) Verify(rawToken []byte) (hashedPatientID string, scope []string, err error) {
	var tok QRScopeToken
	if err := json.Unmarshal(rawToken, &tok); err != nil {
		return "", nil, fmt.Errorf("qr token parse: %w", err)
	}

	if err := validateHash(tok.HashedPatientID); err != nil {
		return "", nil, fmt.Errorf("qr token sub: %w", err)
	}

	if len(tok.Scope) == 0 {
		return "", nil, errors.New("qr token: scope is empty")
	}
	for _, s := range tok.Scope {
		if !allowedIPSScopes[s] {
			return "", nil, fmt.Errorf("qr token: scope %q is not in the IPS emergency subset", s)
		}
	}

	issued := time.Unix(tok.IssuedAt, 0).UTC()
	now := time.Now().UTC()
	if now.Before(issued) {
		return "", nil, errors.New("qr token: issued in the future")
	}
	if now.After(issued.Add(QRTokenTTL)) {
		return "", nil, errors.New("qr token: expired")
	}

	sigBytes, err := base64.RawURLEncoding.DecodeString(tok.Sig)
	if err != nil {
		return "", nil, fmt.Errorf("qr token sig decode: %w", err)
	}

	// Reconstruct the canonical payload that was signed: the token without the sig field.
	canonical, err := canonicalPayload(tok)
	if err != nil {
		return "", nil, fmt.Errorf("qr token canonical payload: %w", err)
	}

	pubKey, err := v.getPatientPubKey(tok.HashedPatientID)
	if err != nil {
		return "", nil, fmt.Errorf("qr token pubkey lookup: %w", err)
	}

	if !ed25519.Verify(pubKey, canonical, sigBytes) {
		return "", nil, errors.New("qr token: signature invalid")
	}

	return tok.HashedPatientID, tok.Scope, nil
}

// canonicalPayload serialises the unsigned fields in a deterministic order for
// signature verification. Must match exactly what the iOS wallet signs.
func canonicalPayload(tok QRScopeToken) ([]byte, error) {
	unsigned := struct {
		Sub   string   `json:"sub"`
		Scope []string `json:"scope"`
		IAT   int64    `json:"iat"`
	}{
		Sub:   tok.HashedPatientID,
		Scope: tok.Scope,
		IAT:   tok.IssuedAt,
	}
	return json.Marshal(unsigned)
}
