package main

import (
	"encoding/json"
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// MilitaryContract implements channel 4: STANAG 2154 military health audit.
//
// Endorsement policy (configured in configtx.yaml, enforced outside chaincode):
//   MEDEVAC:       1-of-2 orgs — field speed over certainty
//   Forensic:      2-of-2 orgs — DVI identification certainty
//   BulkRegister:  2-of-2 orgs + admin MSP signature
//   All others:    2-of-2 standard
//
// INVARIANT: Every field written to world state is a SHA3-256 hex hash,
// a string enum, a primitive, or a Fabric txID.
// Fields never stored: PII, clearance, unit designation, rank, or coordinates.
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

func validateAuthority(authority string) error {
	if !validAuthorities[authority] {
		return fmt.Errorf("unknown authority %q", authority)
	}
	return nil
}

func validateAccessScope(scope []string) error {
	if len(scope) == 0 {
		return fmt.Errorf("accessScope must contain at least one element")
	}
	return nil
}

func validateRoutingPath(path string) error {
	valid := map[string]bool{
		"direct": true, "via_duty_officer": true, "via_europol_siena": true,
	}
	if !valid[path] {
		return fmt.Errorf("routingPath must be 'direct', 'via_duty_officer', or 'via_europol_siena', got %q", path)
	}
	return nil
}

func validateNotificationType(t string) error {
	valid := map[string]bool{"injured": true, "kia": true, "missing": true, "found": true}
	if !valid[t] {
		return fmt.Errorf("notificationType must be 'injured', 'kia', 'missing', or 'found', got %q", t)
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
// operationalRole: OperationalRole value (e.g. "gendarmerie", "specialOps")
// authority: AuthorityType value (e.g. "ua_mo", "eu_gendarmerie", "nato")
// legalBasis: LegalBasisType value (e.g. "nato_stanag", "led_art10")
func (c *MilitaryContract) RegisterMilitaryProfile(
	ctx contractapi.TransactionContextInterface,
	serviceNumberHash string,
	nationalityCode string,
	dnaReferenceHash string,
	operationalRole string,
	authority string,
	legalBasis string,
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
	if !validOperationalRoles[operationalRole] {
		return fmt.Errorf("unknown operationalRole %q", operationalRole)
	}
	if err := validateAuthority(authority); err != nil {
		return err
	}
	if !validLegalBases[legalBasis] {
		return fmt.Errorf("unknown legalBasis %q", legalBasis)
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
		OperationalRole:   operationalRole,
		Authority:         authority,
		LegalBasis:        legalBasis,
		RegisteredAt:      fmt.Sprintf("%d", ts.Seconds),
		TxID:              ctx.GetStub().GetTxID(),
	}
	return putJSON(ctx, key, rec)
}

// RecordMEDEVACAccess logs a paramedic reading a military emergency card in the field.
// Endorsement policy: 1-of-2 peers (field speed — no time for 2-of-2).
// locationHash must be SHA3-256(grid_coords) — never plaintext coordinates.
// crossBorder: true if access is in a different country from the profile's registration.
func (c *MilitaryContract) RecordMEDEVACAccess(
	ctx contractapi.TransactionContextInterface,
	patientHash string,
	medicHash string,
	locationHash string,
	accessScope []string,
	authority string,
	crossBorder bool,
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
	if err := validateAuthority(authority); err != nil {
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
		AccessorType: "medic",
		Authority:    authority,
		AccessScope:  accessScope,
		LocationHash: locationHash,
		Timestamp:    fmt.Sprintf("%d", ts.Seconds),
		CrossBorder:  crossBorder,
		TxID:         txID,
	}
	key, err := ctx.GetStub().CreateCompositeKey("MIL", []string{patientHash, txID})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	return putJSON(ctx, key, rec)
}

// RecordForensicAccess logs a DVI team reading identifying marks for victim identification.
// Endorsement policy: 2-of-2 peers (identification certainty — no rush).
// eucpReference: UCPM coordination reference if EU civil protection involved; empty otherwise.
func (c *MilitaryContract) RecordForensicAccess(
	ctx contractapi.TransactionContextInterface,
	patientHash string,
	dviTeamHash string,
	accessScope []string,
	authority string,
	eucpReference string,
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
	if err := validateAuthority(authority); err != nil {
		return err
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &ForensicAccessRecord{
		PatientHash:   patientHash,
		DVITeamHash:   dviTeamHash,
		Authority:     authority,
		AccessScope:   accessScope,
		EUCPReference: eucpReference,
		Timestamp:     fmt.Sprintf("%d", ts.Seconds),
		TxID:          txID,
	}
	key, err := ctx.GetStub().CreateCompositeKey("FORENSIC", []string{patientHash, txID})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	return putJSON(ctx, key, rec)
}

// RecordNOKNotification logs a next-of-kin notification event.
// nokHash is SHA3-256(nok_phone) — never the phone number itself.
// routingPath: "direct" | "via_duty_officer" | "via_europol_siena"
func (c *MilitaryContract) RecordNOKNotification(
	ctx contractapi.TransactionContextInterface,
	patientHash string,
	nokHash string,
	notificationType string,
	routingPath string,
	authority string,
) error {
	if err := validateHash(patientHash, "patientHash"); err != nil {
		return err
	}
	if err := validateHash(nokHash, "nokHash"); err != nil {
		return err
	}
	if err := validateNotificationType(notificationType); err != nil {
		return err
	}
	if err := validateRoutingPath(routingPath); err != nil {
		return err
	}
	if err := validateAuthority(authority); err != nil {
		return err
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
		RoutingPath:      routingPath,
		Authority:        authority,
		Timestamp:        fmt.Sprintf("%d", ts.Seconds),
		TxID:             txID,
	}
	key, err := ctx.GetStub().CreateCompositeKey("NOK", []string{patientHash, txID})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	return putJSON(ctx, key, rec)
}

// BulkRegisterProfiles registers a battalion/corporate/family import batch on-chain.
// Endorsement policy: 2-of-2 peers + admin MSP signature (configured at channel level).
// profileHashes: each must be SHA3-256(service_number) — 64 lowercase hex chars.
// batchReference: SHA3-256(admin_id + timestamp) — never the admin's plaintext identity.
//
// SECURITY: proposerAdminHash and approverAdminHash MUST be distinct SHA3-256 hashes
// of two different admin identities. This prevents a single compromised admin account
// from self-approving a bulk registration of thousands of military profiles.
// Attack vector without this check: one compromised admin signs both propose and approve,
// silently enrolling 50,000 soldiers under adversary-controlled identities.
func (c *MilitaryContract) BulkRegisterProfiles(
	ctx contractapi.TransactionContextInterface,
	profileHashes []string,
	tenantHash string,
	authority string,
	batchReference string,
	proposerAdminHash string,
	approverAdminHash string,
) error {
	if err := validateHash(tenantHash, "tenantHash"); err != nil {
		return err
	}
	if err := validateAuthority(authority); err != nil {
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

	// CRITICAL: Two-admin separation — proposer and approver must be distinct identities.
	// This mirrors the ForceAssemble/ReassignRole pattern and prevents single-admin abuse.
	if err := validateHash(proposerAdminHash, "proposerAdminHash"); err != nil {
		return err
	}
	if err := validateHash(approverAdminHash, "approverAdminHash"); err != nil {
		return err
	}
	if proposerAdminHash == approverAdminHash {
		return fmt.Errorf("proposerAdminHash and approverAdminHash must be distinct — " +
			"two different admins are required to authorise a bulk registration")
	}

	key, err := ctx.GetStub().CreateCompositeKey("BULK", []string{tenantHash, batchReference})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	existing, _ := ctx.GetStub().GetState(key)
	if existing != nil {
		return fmt.Errorf("batch %q already registered for tenant %s", batchReference, tenantHash)
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &BulkRegistrationRecord{
		TenantHash:        tenantHash,
		ProfileHashes:     profileHashes,
		Authority:         authority,
		BatchReference:    batchReference,
		ProposerAdminHash: proposerAdminHash,
		ApproverAdminHash: approverAdminHash,
		ProfileCount:      len(profileHashes),
		Timestamp:         fmt.Sprintf("%d", ts.Seconds),
		TxID:              txID,
	}
	return putJSON(ctx, key, rec)
}

// GetMilitaryAuditTrail returns the full MEDEVAC audit trail for a given patient hash.
// Used for STANAG 2154 reporting and GDPR Art.15 right-of-access responses.
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
