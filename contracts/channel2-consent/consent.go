package main

import (
	"encoding/json"
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ConsentAuditContract implements channel 2: GDPR Art.7 consent lifecycle.
//
// Design invariants:
//   - Every write is an append — revocation does NOT mutate the grant record.
//   - Cross-channel reference: signatureTxHash links each consent to a channel-1 AdES record.
//   - userIdHash must be SHA3-256(salt+userID); salt is in HSM, never on-chain.
//   - Revocation is immediate; no grace period; the previous grant record is unchanged.
type ConsentAuditContract struct {
	contractapi.Contract
}

// ─── Validation ───────────────────────────────────────────────────────────────

func validateConsentHash(h string) error {
	if len(h) != 64 {
		return fmt.Errorf("invalid hash: expected 64 lowercase hex chars, got %d", len(h))
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return fmt.Errorf("invalid hash: contains non-hex character '%c'", c)
		}
	}
	return nil
}

func validateConsentType(ct string) error {
	if !validConsentTypes[ct] {
		return fmt.Errorf("unknown consent type %q", ct)
	}
	return nil
}

// ─── Storage helpers ──────────────────────────────────────────────────────────

func putConsentRecord(ctx contractapi.TransactionContextInterface, rec *ConsentAuditRecord) error {
	// Composite key: CONSENT~userIdHash~txID
	// The txID segment makes every record unique; partial-key query on userIdHash
	// returns the full ordered history for a user.
	key, err := ctx.GetStub().CreateCompositeKey("CONSENT", []string{rec.UserIdHash, rec.TxID})
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("cannot marshal consent record: %w", err)
	}
	return ctx.GetStub().PutState(key, data)
}

// ─── Public chaincode functions ───────────────────────────────────────────────

// RecordConsentGrant writes an immutable consent-granted event to channel 2.
//
// Parameters:
//   - userIdHash:      SHA3-256(salt+userID) of the consenting patient
//   - consentType:     one of the approved consent categories
//   - expiresAt:       Unix timestamp of expiry; 0 = indefinite
//   - signatureTxHash: txID from channel 1 (RecordAdESSignature) for this consent document
//
// Returns the Fabric txID so the iOS app can store it in the Legal vault
// alongside the local ConsentRecord.
func (c *ConsentAuditContract) RecordConsentGrant(
	ctx contractapi.TransactionContextInterface,
	userIdHash string,
	consentType string,
	expiresAt int64,
	signatureTxHash string,
) (string, error) {
	if err := validateConsentHash(userIdHash); err != nil {
		return "", fmt.Errorf("userIdHash: %w", err)
	}
	if err := validateConsentType(consentType); err != nil {
		return "", err
	}
	if len(signatureTxHash) == 0 {
		return "", fmt.Errorf("signatureTxHash must reference a channel-1 txID")
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return "", fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &ConsentAuditRecord{
		UserIdHash:      userIdHash,
		ConsentType:     consentType,
		Event:           "granted",
		ExpiresAt:       expiresAt,
		SignatureTxHash: signatureTxHash,
		RecordedAt:      ts.Seconds,
		TxID:            txID,
	}
	if err := putConsentRecord(ctx, rec); err != nil {
		return "", err
	}

	// Emit chaincode event so the gatekeeper ConsentWatcher can clear any active
	// revoke:{userIdHash} key in Redis when consent is re-established.
	evtPayload, err := json.Marshal(struct {
		UserIdHash  string `json:"userIdHash"`
		ConsentType string `json:"consentType"`
	}{UserIdHash: userIdHash, ConsentType: consentType})
	if err != nil {
		return "", fmt.Errorf("marshal ConsentGranted event: %w", err)
	}
	if err := ctx.GetStub().SetEvent("ConsentGranted", evtPayload); err != nil {
		return "", fmt.Errorf("SetEvent ConsentGranted: %w", err)
	}

	return txID, nil
}

// RecordConsentRevoke appends a consent-revoked event for the given user and consent type.
//
// Revocation is IMMEDIATE with no grace period (GDPR Art.7(3) requirement).
// The original grant record is NOT modified — the ledger is append-only.
// Callers must treat the most recent event for a (userIdHash, consentType) pair
// as authoritative; if it is "revoked", the consent is withdrawn.
//
// revokedAt should be the Unix timestamp of the patient's explicit revocation action
// on their device (may differ slightly from RecordedAt due to network latency).
func (c *ConsentAuditContract) RecordConsentRevoke(
	ctx contractapi.TransactionContextInterface,
	userIdHash string,
	consentType string,
	revokedAt int64,
) (string, error) {
	if err := validateConsentHash(userIdHash); err != nil {
		return "", fmt.Errorf("userIdHash: %w", err)
	}
	if err := validateConsentType(consentType); err != nil {
		return "", err
	}
	if revokedAt <= 0 {
		return "", fmt.Errorf("revokedAt must be a positive Unix timestamp")
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return "", fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &ConsentAuditRecord{
		UserIdHash:      userIdHash,
		ConsentType:     consentType,
		Event:           "revoked",
		ExpiresAt:       revokedAt, // reuse field to record when revocation took effect
		SignatureTxHash: "",        // revocations do not require a new AdES signature
		RecordedAt:      ts.Seconds,
		TxID:            txID,
	}
	if err := putConsentRecord(ctx, rec); err != nil {
		return "", err
	}

	// Emit chaincode event so the gatekeeper ConsentWatcher can SET revoke:{userIdHash}
	// in Redis. The watcher then gates all physician access for this patient until
	// consent is re-established (ConsentGranted event clears the key).
	evtPayload, err := json.Marshal(struct {
		UserIdHash  string `json:"userIdHash"`
		ConsentType string `json:"consentType"`
	}{UserIdHash: userIdHash, ConsentType: consentType})
	if err != nil {
		return "", fmt.Errorf("marshal ConsentRevoked event: %w", err)
	}
	if err := ctx.GetStub().SetEvent("ConsentRevoked", evtPayload); err != nil {
		return "", fmt.Errorf("SetEvent ConsentRevoked: %w", err)
	}

	return txID, nil
}

// GetConsentHistory returns all consent events for a given userIdHash, ordered by txID.
// Used for GDPR Art.15 right-of-access responses. Returns an empty slice (not an error)
// if no records exist.
func (c *ConsentAuditContract) GetConsentHistory(
	ctx contractapi.TransactionContextInterface,
	userIdHash string,
) ([]*ConsentAuditRecord, error) {
	if err := validateConsentHash(userIdHash); err != nil {
		return nil, fmt.Errorf("userIdHash: %w", err)
	}

	iter, err := ctx.GetStub().GetStateByPartialCompositeKey("CONSENT", []string{userIdHash})
	if err != nil {
		return nil, fmt.Errorf("consent history query failed: %w", err)
	}
	defer iter.Close()

	var records []*ConsentAuditRecord
	for iter.HasNext() {
		result, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("consent history iteration error: %w", err)
		}
		var rec ConsentAuditRecord
		if err := json.Unmarshal(result.Value, &rec); err != nil {
			return nil, fmt.Errorf("cannot unmarshal consent record: %w", err)
		}
		records = append(records, &rec)
	}
	return records, nil
}
