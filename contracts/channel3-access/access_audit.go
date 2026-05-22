package main

import (
	"encoding/json"
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AccessAuditContract implements channel 3: GDPR Art.15 eHR access audit log.
//
// This channel records ACTUAL DATA READS — when a clinician opened a patient's record.
// It is distinct from the access-control chaincode (contracts/) which records PERMISSION
// grants and revocations. Both are required to answer a GDPR Art.15 request completely.
//
// Cross-channel references:
//   consentRef  → channel-2 txID (the consent that authorised this access)
//   signatureRef → channel-1 txID (the accessor's AdES session signature)
type AccessAuditContract struct {
	contractapi.Contract
}

// ─── Validation ───────────────────────────────────────────────────────────────

func validateAccessHash(h string) error {
	if len(h) != 64 {
		return fmt.Errorf("invalid hash: expected 64 lowercase hex chars, got %d", len(h))
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return fmt.Errorf("invalid hash: non-hex character '%c'", c)
		}
	}
	return nil
}

func validateAccessorType(t string) error {
	if !validAccessorTypes[t] {
		return fmt.Errorf("unknown accessor type %q", t)
	}
	return nil
}

func validateAccessScope(scope []string) error {
	if len(scope) == 0 {
		return fmt.Errorf("accessScope must contain at least one FHIR resource type")
	}
	for _, r := range scope {
		if !validFHIRResources[r] {
			return fmt.Errorf("unknown FHIR resource type %q in accessScope", r)
		}
	}
	return nil
}

// ─── Storage helpers ──────────────────────────────────────────────────────────

func putAccessAuditRecord(ctx contractapi.TransactionContextInterface, rec *AccessAuditRecord) error {
	// Composite key: ACCESS~patientIdHash~txID
	// Partial-key range query on patientIdHash returns ordered full access history.
	key, err := ctx.GetStub().CreateCompositeKey("ACCESS", []string{rec.PatientIdHash, rec.TxID})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("cannot marshal access audit record: %w", err)
	}
	return ctx.GetStub().PutState(key, data)
}

// ─── Public chaincode functions ───────────────────────────────────────────────

// RecordEHRAccess logs a single eHR data access event to channel 3.
//
// Called by the Gatekeeper service immediately after it delivers a pre-signed
// MinIO URL to the accessor. The Gatekeeper knows: who asked, what they accessed,
// which consent authorised it, and the accessor's session signature txID.
//
// Parameters:
//   - patientIdHash:  SHA3-256(salt+patientID)
//   - accessorIdHash: SHA3-256(salt+accessorID)
//   - accessorType:   role enum (er_doctor, insurer, researcher, ...)
//   - licenseHash:    SHA3-256 of the accessor's professional licence DER bytes
//   - accessScope:    FHIR resource types that were returned (from the API response)
//   - duration:       seconds the pre-signed URL was valid (always ≤120s per architecture)
//   - consentRef:     channel-2 txID of the consent that authorised this access
//   - signatureRef:   channel-1 txID of the accessor's AdES session signature
//
// Returns the Fabric txID for the access event record.
func (c *AccessAuditContract) RecordEHRAccess(
	ctx contractapi.TransactionContextInterface,
	patientIdHash string,
	accessorIdHash string,
	accessorType string,
	licenseHash string,
	accessScope []string,
	duration int32,
	consentRef string,
	signatureRef string,
) (string, error) {
	if err := validateAccessHash(patientIdHash); err != nil {
		return "", fmt.Errorf("patientIdHash: %w", err)
	}
	if err := validateAccessHash(accessorIdHash); err != nil {
		return "", fmt.Errorf("accessorIdHash: %w", err)
	}
	if patientIdHash == accessorIdHash {
		return "", fmt.Errorf("patientIdHash and accessorIdHash must differ")
	}
	if err := validateAccessorType(accessorType); err != nil {
		return "", err
	}
	if err := validateAccessHash(licenseHash); err != nil {
		return "", fmt.Errorf("licenseHash: %w", err)
	}
	if err := validateAccessScope(accessScope); err != nil {
		return "", err
	}
	if duration <= 0 || duration > 120 {
		return "", fmt.Errorf("duration must be between 1 and 120 seconds (pre-signed URL TTL)")
	}
	if len(consentRef) == 0 {
		return "", fmt.Errorf("consentRef must reference a channel-2 txID")
	}
	if len(signatureRef) == 0 {
		return "", fmt.Errorf("signatureRef must reference a channel-1 txID")
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return "", fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &AccessAuditRecord{
		PatientIdHash:  patientIdHash,
		AccessorIdHash: accessorIdHash,
		AccessorType:   accessorType,
		LicenseHash:    licenseHash,
		AccessScope:    accessScope,
		Duration:       duration,
		ConsentRef:     consentRef,
		SignatureRef:   signatureRef,
		RecordedAt:     ts.Seconds,
		TxID:           txID,
	}
	if err := putAccessAuditRecord(ctx, rec); err != nil {
		return "", err
	}
	return txID, nil
}

// GetAccessHistory returns all access audit records for a given patient (GDPR Art.15).
// Returns an empty slice (not an error) if no records exist.
// Results are ordered by txID within the patientIdHash composite key prefix.
func (c *AccessAuditContract) GetAccessHistory(
	ctx contractapi.TransactionContextInterface,
	patientIdHash string,
) ([]*AccessAuditRecord, error) {
	if err := validateAccessHash(patientIdHash); err != nil {
		return nil, fmt.Errorf("patientIdHash: %w", err)
	}

	iter, err := ctx.GetStub().GetStateByPartialCompositeKey("ACCESS", []string{patientIdHash})
	if err != nil {
		return nil, fmt.Errorf("access history query failed: %w", err)
	}
	defer iter.Close()

	var records []*AccessAuditRecord
	for iter.HasNext() {
		result, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("access history iteration error: %w", err)
		}
		var rec AccessAuditRecord
		if err := json.Unmarshal(result.Value, &rec); err != nil {
			return nil, fmt.Errorf("cannot unmarshal access audit record: %w", err)
		}
		records = append(records, &rec)
	}
	return records, nil
}
