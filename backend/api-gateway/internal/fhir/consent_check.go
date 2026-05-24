// consent_check.go — FHIR consent verification before partner data access.
//
// Special cases enforced here:
//
//  1. mental_health partner writes to Condition require a separate consent record
//     (consent_type = "mental_health_sensitive") in Redis — distinct from standard
//     GDPR Art.9 consent managed by the gatekeeper.
//
//  2. mental_health resource writes are NEVER included in the emergency QR scope.
//     The emergency-scope flag in patient consent must be absent or false.
//
//  3. Every mental_health access is labeled "sensitive" in the Fabric audit record
//     written to channel 3 (access-audit). The audit record contains only hashes.
//
// Consent records are keyed by the patient's SHA3-256 hash (never plaintext ID).
package fhir

import (
	"context"
	"errors"
	"fmt"

	"github.com/redis/go-redis/v9"

	"github.com/nobordershealthcare/api-gateway/internal/partner"
)

// ConsentChecker verifies patient consent for partner resource access.
type ConsentChecker struct {
	rdb *redis.Client
}

func NewConsentChecker(rdb *redis.Client) *ConsentChecker {
	return &ConsentChecker{rdb: rdb}
}

// ConsentResult contains the outcome and any special metadata for audit purposes.
type ConsentResult struct {
	Allowed     bool
	IsSensitive bool   // true for mental_health — must be flagged in blockchain audit
	DenialReason string
}

// consentKeyForPatient returns the Redis key for a patient's consent record.
// patientHash must be SHA3-256(salt+patientID) — never the raw identifier.
func consentKeyForPatient(patientHash, consentType string) string {
	return fmt.Sprintf("consent:%s:%s", patientHash, consentType)
}

// emergencyScopeKey returns the Redis key that gates emergency QR access for a patient.
func emergencyScopeKey(patientHash string) string {
	return fmt.Sprintf("consent:%s:emergency_scope", patientHash)
}

// Check verifies consent for a partner access.
//
//   - patientHash must be 64 hex chars (SHA3-256 output) — never a raw ID.
//   - resourceType is the FHIR resource type being accessed (e.g. "Condition").
//   - partnerType determines which consent check path applies.
//
// For mental_health: checks for the "mental_health_sensitive" consent record AND
// verifies the resource is not in emergency scope (emergency QR must never expose
// mental health data).
func (cc *ConsentChecker) Check(
	ctx context.Context,
	patientHash string,
	pt partner.PartnerType,
	resourceType string,
) (*ConsentResult, error) {
	if len(patientHash) != 64 {
		return nil, errors.New("consent check: patientHash must be 64 hex chars (SHA3-256)")
	}

	if pt == partner.PartnerTypeMentalHealth {
		return cc.checkMentalHealth(ctx, patientHash, resourceType)
	}

	// Standard consent: verify the general GDPR Art.9 healthcare-partner consent.
	key := consentKeyForPatient(patientHash, "healthcare_partner")
	granted, err := cc.rdb.Get(ctx, key).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return &ConsentResult{
				Allowed:      false,
				DenialReason: "no healthcare partner consent on record",
			}, nil
		}
		return nil, fmt.Errorf("consent lookup: %w", err)
	}
	if granted != "1" {
		return &ConsentResult{
			Allowed:      false,
			DenialReason: "healthcare partner consent not granted",
		}, nil
	}
	return &ConsentResult{Allowed: true, IsSensitive: false}, nil
}

// checkMentalHealth enforces the three invariants for mental_health partner type:
//  1. "mental_health_sensitive" consent must be explicitly granted.
//  2. The resource must NOT be in emergency scope.
//  3. Returns IsSensitive=true so the caller can label the Fabric audit entry.
func (cc *ConsentChecker) checkMentalHealth(
	ctx context.Context,
	patientHash string,
	resourceType string,
) (*ConsentResult, error) {
	// Invariant 1: explicit mental_health_sensitive consent required.
	mhKey := consentKeyForPatient(patientHash, "mental_health_sensitive")
	mhGranted, err := cc.rdb.Get(ctx, mhKey).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return &ConsentResult{
				Allowed:      false,
				IsSensitive:  true,
				DenialReason: "mental_health_sensitive consent not on record",
			}, nil
		}
		return nil, fmt.Errorf("mental health consent lookup: %w", err)
	}
	if mhGranted != "1" {
		return &ConsentResult{
			Allowed:      false,
			IsSensitive:  true,
			DenialReason: "mental_health_sensitive consent not granted",
		}, nil
	}

	// Invariant 2: must not be in emergency scope.
	emKey := emergencyScopeKey(patientHash)
	emScope, err := cc.rdb.Get(ctx, emKey).Result()
	if err != nil && !errors.Is(err, redis.Nil) {
		return nil, fmt.Errorf("emergency scope lookup: %w", err)
	}
	if emScope == "1" {
		// Patient has emergency QR enabled — mental health data must not be accessible
		// via that path. Block this specific combination.
		return &ConsentResult{
			Allowed:      false,
			IsSensitive:  true,
			DenialReason: "mental health resources cannot be in emergency scope",
		}, nil
	}

	// All invariants satisfied.
	return &ConsentResult{
		Allowed:     true,
		IsSensitive: true, // ALWAYS true for mental_health — caller must audit as "sensitive"
	}, nil
}
