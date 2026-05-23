// Package jwtverify verifies the patient's self-signed EdDSA JWT.
//
// The patient's JWT embeds the signer's Ed25519 public key in the "pk" claim
// (raw 32-byte representation, base64url-encoded). Verification steps:
//   1. Algorithm pinning — header.alg must equal "EdDSA"
//   2. Expiry — exp claim must be in the future
//   3. Key extraction — decode "pk" claim → 32-byte ed25519.PublicKey
//   4. Signature — ed25519.Verify(pubKey, header+"."+payload, sig)
//
// There is no centralized public-key registry; each JWT is self-verifying and
// can be validated offline. The relying party (ER doctor) trusts the data
// displayed on the phone screen and independently verifies via this endpoint.
//
// Hash rule: SHA3-256 everywhere (golang.org/x/crypto/sha3) — NEVER crypto/sha256.
package jwtverify

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ErrAlgorithm is returned when the JWT header specifies an unexpected algorithm.
var ErrAlgorithm = errors.New("jwt: algorithm must be EdDSA")

// ErrExpired is returned when the JWT exp claim is in the past.
var ErrExpired = errors.New("jwt: token expired")

// ErrSignature is returned when the Ed25519 signature does not match.
var ErrSignature = errors.New("jwt: invalid signature")

// ErrMissingClaim is returned when a required claim is absent.
var ErrMissingClaim = errors.New("jwt: missing required claim")

// PatientClaims holds the decoded payload fields from a patient emergency QR JWT.
// No PII processing — sub is SHA3-256(salt+userID), displayName is patient-chosen
// (first name + last initial only, max 50 chars, set by patient during onboarding).
type PatientClaims struct {
	Sub         string              `json:"sub"`
	Name        string              `json:"name"`
	DOB         string              `json:"dob"`
	Blood       string              `json:"blood"`
	Allergies   []string            `json:"allergies"`
	Medications []map[string]string `json:"medications"` // name, dose, freq, atc (optional)
	Lang        string              `json:"lang"`
	PK          string              `json:"pk"` // raw Ed25519 public key, base64url
	IAT         int64               `json:"iat"`
	EXP         int64               `json:"exp"`
	JTI         string              `json:"jti"`
}

// Verify parses and cryptographically validates a patient JWT.
// Returns the decoded claims on success. Returns a typed error on failure.
func Verify(tokenStr string) (*PatientClaims, error) {
	parts := strings.Split(tokenStr, ".")
	if len(parts) != 3 {
		return nil, errors.New("jwt: malformed — expected 3 parts")
	}

	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, fmt.Errorf("jwt: decode header: %w", err)
	}

	var header struct {
		Alg string `json:"alg"`
		Typ string `json:"typ"`
	}
	if err := json.Unmarshal(headerJSON, &header); err != nil {
		return nil, fmt.Errorf("jwt: parse header: %w", err)
	}
	if header.Alg != "EdDSA" {
		return nil, ErrAlgorithm
	}

	payloadJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("jwt: decode payload: %w", err)
	}

	var claims PatientClaims
	if err := json.Unmarshal(payloadJSON, &claims); err != nil {
		return nil, fmt.Errorf("jwt: parse claims: %w", err)
	}

	if claims.EXP == 0 {
		return nil, ErrMissingClaim
	}
	if time.Unix(claims.EXP, 0).Before(time.Now().UTC()) {
		return nil, ErrExpired
	}
	if claims.JTI == "" {
		return nil, fmt.Errorf("%w: jti", ErrMissingClaim)
	}
	if claims.Sub == "" {
		return nil, fmt.Errorf("%w: sub", ErrMissingClaim)
	}
	if claims.PK == "" {
		return nil, fmt.Errorf("%w: pk", ErrMissingClaim)
	}

	// Decode the embedded public key (raw 32-byte Ed25519 representation, base64url).
	pkBytes, err := base64.RawURLEncoding.DecodeString(claims.PK)
	if err != nil {
		return nil, fmt.Errorf("jwt: decode pk claim: %w", err)
	}
	if len(pkBytes) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("jwt: pk must be %d bytes, got %d", ed25519.PublicKeySize, len(pkBytes))
	}
	pubKey := ed25519.PublicKey(pkBytes)

	sigBytes, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, fmt.Errorf("jwt: decode signature: %w", err)
	}

	// Signing input is the ASCII bytes of "base64url(header).base64url(payload)"
	signingInput := []byte(parts[0] + "." + parts[1])
	if !ed25519.Verify(pubKey, signingInput, sigBytes) {
		return nil, ErrSignature
	}

	return &claims, nil
}
