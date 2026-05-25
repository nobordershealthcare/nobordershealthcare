package main

import (
	"encoding/json"
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// MilitaryContract implements channel 4: STANAG 2154 military health audit.
//
// Endorsement policy (configured at channel level, enforced outside chaincode):
//   MEDEVAC:       1-of-2 peers (fast — field conditions)
//   Forensic:      2-of-2 peers (higher stakes — DVI identification)
//   BulkRegister:  2-of-2 peers + admin signature
//
// INVARIANT: Every field written to world state is a SHA3-256 hex hash,
// a string enum, a primitive, or a Fabric txID.
// No PII, no coordinates, no clearance, no unit, no rank.
type MilitaryContract struct {
	contractapi.Contract
}

// ─── Validation helpers ───────────────────────────────────────────────────────

func validateHash(h string, fieldName string) error {
	if len(h) != 64 {
		return fmt.Errorf("%s: expected 64 lowercase hex chars, got %d", fieldName, len(h))
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return fmt.Errorf("%s: contains non-hex character '%c'", fieldName, c)
		}
	}
	return nil
}

func validateAccessScope(scope []string) error {
	if len(scope) == 0 {
		return fmt.Errorf("accessScope must contain at least one element")
	}
	return nil
}

// ─── Storage helpers ──────────────────────────────────────────────────────────

func putJSON(ctx contractapi.TransactionContextInterface, key string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("marshal error: %w", err)
	}
	return ctx.GetStub().PutState(key, data)
}

func getHistoryByPartialKey(ctx contractapi.TransactionContextInterface, objectType string, keys []string) ([][]byte, error) {
	iter, err := ctx.GetStub().GetStateByPartialCompositeKey(objectType, keys)
	if err != nil {
		return nil, fmt.Errorf("partial key query failed: %w", err)
	}
	defer iter.Close()

	var results [][]byte
	for iter.HasNext() {
		item, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("iterator error: %w", err)
		}
		results = append(results, item.Value)
	}
	return results, nil
}

// ─── Public chaincode functions ───────────────────────────────────────────────

// RegisterMilitaryProfile registers a military profile hash on-chain.
// Called once during profile activation via the admin portal.
// Writes only hashes — never plaintext serviceNumber or dnaRefNumber.
func (c *MilitaryContract) RegisterMilitaryProfile(
	ctx contractapi.TransactionContextInterface,
	serviceNumberHash string,
	nationalityCode string,
	dnaReferenceHash string,
	profileType string,
) error {
	if err := validateHash(serviceNumberHash, "serviceNumberHash"); err != nil {
		return err
	}
	if !isValidISO3166Alpha2(nationalityCode) {
		return fmt.Errorf("nationalityCode must be ISO 3166-1 alpha-2 (2 chars)")
	}
	if err := validateHash(dnaReferenceHash, "dnaReferenceHash"); err != nil {
		return err
	}
	if !validProfileTypes[profileType] {
		return fmt.Errorf("profileType must be 'military' or 'firstResponder', got %q", profileType)
	}

	key, err := ctx.GetStub().CreateCompositeKey("MILPROFILE", []string{serviceNumberHash})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	existing, _ := ctx.GetStub().GetState(key)
	if existing != nil {
		return fmt.Errorf("military profile already registered for serviceNumberHash %s", serviceNumberHash)
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	rec := &MilitaryProfileRecord{
		ServiceNumberHash: serviceNumberHash,
		NationalityCode:   nationalityCode,
		DNAReferenceHash:  dnaReferenceHash,
		ProfileType:       profileType,
		RegisteredAt:      ts.Seconds,
		TxID:              ctx.GetStub().GetTxID(),
	}
	return putJSON(ctx, key, rec)
}

// RecordMEDEVACAccess logs a paramedic reading a military emergency card in the field.
// Endorsement policy: 1-of-2 peers (prioritises field speed).
// locationHash must be SHA3-256(grid_coords) — never plaintext coordinates.
func (c *MilitaryContract) RecordMEDEVACAccess(
	ctx contractapi.TransactionContextInterface,
	patientHash string,
	medicHash string,
	locationHash string,
	accessScope []string,
	timestamp string,
) error {
	if err := validateHash(patientHash, "patientHash"); err != nil {
		return err
	}
	if err := validateHash(medicHash, "medicHash"); err != nil {
		return err
	}
	if err := validateHash(locationHash, "locationHash"); err != nil {
		return err
	}
	if err := validateAccessScope(accessScope); err != nil {
		return err
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &MilitaryAccessRecord{
		PatientHash:  patientHash,
		AccessorHash: medicHash,
		AccessorType: "medevac_medic",
		AccessScope:  accessScope,
		LocationHash: locationHash,
		RecordedAt:   ts.Seconds,
		TxID:         txID,
	}
	key, err := ctx.GetStub().CreateCompositeKey("MIL", []string{patientHash, txID})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	return putJSON(ctx, key, rec)
}

// RecordForensicAccess logs a DVI team reading identifying marks for victim identification.
// Endorsement policy: 2-of-2 peers (higher stakes than MEDEVAC).
func (c *MilitaryContract) RecordForensicAccess(
	ctx contractapi.TransactionContextInterface,
	patientHash string,
	dviTeamHash string,
	accessScope []string,
) error {
	if err := validateHash(patientHash, "patientHash"); err != nil {
		return err
	}
	if err := validateHash(dviTeamHash, "dviTeamHash"); err != nil {
		return err
	}
	if err := validateAccessScope(accessScope); err != nil {
		return err
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &ForensicAccessRecord{
		PatientHash: patientHash,
		DVITeamHash: dviTeamHash,
		AccessScope: accessScope,
		RecordedAt:  ts.Seconds,
		TxID:        txID,
	}
	key, err := ctx.GetStub().CreateCompositeKey("FORENSIC", []string{patientHash, txID})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	return putJSON(ctx, key, rec)
}

// RecordNOKNotification logs a next-of-kin notification event.
// nokHash is SHA3-256(nok_phone) — never the phone number itself.
func (c *MilitaryContract) RecordNOKNotification(
	ctx contractapi.TransactionContextInterface,
	patientHash string,
	nokHash string,
	notificationType string,
) error {
	if err := validateHash(patientHash, "patientHash"); err != nil {
		return err
	}
	if err := validateHash(nokHash, "nokHash"); err != nil {
		return err
	}
	validTypes := map[string]bool{"injured": true, "kia": true, "missing": true}
	if !validTypes[notificationType] {
		return fmt.Errorf("notificationType must be 'injured', 'kia', or 'missing', got %q", notificationType)
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &NOKNotificationRecord{
		PatientHash:      patientHash,
		NOKHash:          nokHash,
		NotificationType: notificationType,
		RecordedAt:       ts.Seconds,
		TxID:             txID,
	}
	key, err := ctx.GetStub().CreateCompositeKey("NOK", []string{patientHash, txID})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	return putJSON(ctx, key, rec)
}

// BulkRegisterProfiles registers a battalion-level import batch on-chain.
// Called by admin portal — not by individual patients.
// Endorsement policy: 2-of-2 peers + admin signature (configured at channel level).
// profileHashes: each must be SHA3-256(serviceNumber) — 64 lowercase hex chars.
func (c *MilitaryContract) BulkRegisterProfiles(
	ctx contractapi.TransactionContextInterface,
	profileHashes []string,
	tenantHash string,
	batchReference string,
) error {
	if err := validateHash(tenantHash, "tenantHash"); err != nil {
		return err
	}
	if len(batchReference) == 0 {
		return fmt.Errorf("batchReference must not be empty")
	}
	if len(profileHashes) == 0 {
		return fmt.Errorf("profileHashes must not be empty")
	}
	if len(profileHashes) > 10000 {
		return fmt.Errorf("profileHashes exceeds max batch size of 10000 (got %d)", len(profileHashes))
	}
	for i, h := range profileHashes {
		if err := validateHash(h, fmt.Sprintf("profileHashes[%d]", i)); err != nil {
			return err
		}
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &BulkBatchRecord{
		TenantHash:     tenantHash,
		BatchReference: batchReference,
		ProfileHashes:  profileHashes,
		Count:          len(profileHashes),
		RecordedAt:     ts.Seconds,
		TxID:           txID,
	}
	key, err := ctx.GetStub().CreateCompositeKey("BULK", []string{tenantHash, batchReference})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}

	// Reject duplicate batch references for the same tenant.
	existing, _ := ctx.GetStub().GetState(key)
	if existing != nil {
		return fmt.Errorf("batch %q already registered for tenant %s", batchReference, tenantHash)
	}

	return putJSON(ctx, key, rec)
}

// GetMilitaryAuditTrail returns the full MEDEVAC + Forensic + NOK audit trail
// for a given patient hash, for STANAG 2154 reporting.
func (c *MilitaryContract) GetMilitaryAuditTrail(
	ctx contractapi.TransactionContextInterface,
	patientHash string,
) ([]*MilitaryAccessRecord, error) {
	if err := validateHash(patientHash, "patientHash"); err != nil {
		return nil, err
	}

	rawRecords, err := getHistoryByPartialKey(ctx, "MIL", []string{patientHash})
	if err != nil {
		return nil, err
	}

	records := make([]*MilitaryAccessRecord, 0, len(rawRecords))
	for _, raw := range rawRecords {
		var rec MilitaryAccessRecord
		if err := json.Unmarshal(raw, &rec); err != nil {
			return nil, fmt.Errorf("cannot unmarshal MilitaryAccessRecord: %w", err)
		}
		records = append(records, &rec)
	}
	return records, nil
}
