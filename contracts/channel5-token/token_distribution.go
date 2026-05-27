package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// TokenDistributionContract implements channel 5: NBHC token revenue distribution ledger.
//
// Design invariants:
//   - Revenue allocations are immutable once written (one record per period).
//   - Distribution records are append-only; each payout gets its own composite key.
//   - RecordDistribution enforces consent gate — MiCA Art.71 requires explicit holder consent.
//   - holderHash must be SHA3-256(salt+holderAddress); salt is in HSM, never on-chain.
//   - Amounts are stored as micro-EURC integer strings (1 EURC = 1_000_000) to avoid float drift.
type TokenDistributionContract struct {
	contractapi.Contract
}

// ─── Validation ───────────────────────────────────────────────────────────────

func validateHash(h string) error {
	if len(h) != 64 {
		return fmt.Errorf("invalid hash: expected 64 lowercase hex chars, got %d", len(h))
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return fmt.Errorf("invalid hash: non-hex character %q", c)
		}
	}
	return nil
}

// validatePeriod accepts "YYYY-QN" only (e.g. "2026-Q1" … "2026-Q4").
func validatePeriod(p string) error {
	if len(p) != 7 || p[4] != '-' || p[5] != 'Q' || p[6] < '1' || p[6] > '4' {
		return fmt.Errorf("invalid period %q: expected YYYY-QN format (e.g. 2026-Q2)", p)
	}
	return nil
}

// ─── Public chaincode functions ───────────────────────────────────────────────

// RecordRevenueAllocation writes the total EURC revenue figure for a quarter.
// totalRevenue must be a positive integer string in micro-EURC (1 EURC = 1_000_000).
// Only one allocation per period is permitted — overwrites return an error.
func (c *TokenDistributionContract) RecordRevenueAllocation(
	ctx contractapi.TransactionContextInterface,
	period string,
	totalRevenue string,
) (string, error) {
	if err := validatePeriod(period); err != nil {
		return "", err
	}
	if strings.TrimSpace(totalRevenue) == "" {
		return "", fmt.Errorf("totalRevenue must not be empty")
	}

	key, err := ctx.GetStub().CreateCompositeKey("REVENUE", []string{period})
	if err != nil {
		return "", fmt.Errorf("composite key: %w", err)
	}

	existing, err := ctx.GetStub().GetState(key)
	if err != nil {
		return "", fmt.Errorf("state read: %w", err)
	}
	if existing != nil {
		return "", fmt.Errorf("revenue allocation for period %q already recorded — use a corrective distribution record instead", period)
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return "", fmt.Errorf("tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &RevenueAllocation{
		Period:       period,
		TotalRevenue: totalRevenue,
		AllocatedAt:  ts.Seconds,
		TxID:         txID,
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return "", fmt.Errorf("marshal: %w", err)
	}
	if err := ctx.GetStub().PutState(key, data); err != nil {
		return "", fmt.Errorf("put state: %w", err)
	}

	evtPayload, _ := json.Marshal(struct {
		Period string `json:"period"`
	}{Period: period})
	_ = ctx.GetStub().SetEvent("RevenueAllocated", evtPayload)

	return txID, nil
}

// GetRevenueAllocation retrieves the revenue allocation record for a period.
// Returns ErrNotFound (wrapped) if no allocation has been recorded yet.
func (c *TokenDistributionContract) GetRevenueAllocation(
	ctx contractapi.TransactionContextInterface,
	period string,
) (*RevenueAllocation, error) {
	if err := validatePeriod(period); err != nil {
		return nil, err
	}
	key, err := ctx.GetStub().CreateCompositeKey("REVENUE", []string{period})
	if err != nil {
		return nil, fmt.Errorf("composite key: %w", err)
	}
	data, err := ctx.GetStub().GetState(key)
	if err != nil {
		return nil, fmt.Errorf("state read: %w", err)
	}
	if data == nil {
		return nil, fmt.Errorf("no revenue allocation recorded for period %q", period)
	}
	var rec RevenueAllocation
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, fmt.Errorf("unmarshal: %w", err)
	}
	return &rec, nil
}

// RecordDistribution writes a single EURC payout to the ledger.
// paymentRef is the Stripe charge ID or on-chain tx hash returned by the payment dispatcher.
// Returns ErrNoConsent if the holder has not granted MiCA distribution consent.
func (c *TokenDistributionContract) RecordDistribution(
	ctx contractapi.TransactionContextInterface,
	holderHash string,
	amount string,
	period string,
	paymentRef string,
) (string, error) {
	if err := validateHash(holderHash); err != nil {
		return "", fmt.Errorf("holderHash: %w", err)
	}
	if err := validatePeriod(period); err != nil {
		return "", err
	}
	if strings.TrimSpace(amount) == "" {
		return "", fmt.Errorf("amount must not be empty")
	}
	if strings.TrimSpace(paymentRef) == "" {
		return "", fmt.Errorf("paymentRef must not be empty")
	}

	// MiCA Art.71 consent gate — must check before every payout
	ok, err := c.holderHasConsent(ctx, holderHash)
	if err != nil {
		return "", fmt.Errorf("consent check: %w", err)
	}
	if !ok {
		return "", fmt.Errorf("holder %s…has not granted distribution consent (MiCA Art.71)", holderHash[:8])
	}

	// SECURITY: Duplicate-payment guard — one payout per holder per period.
	// The DIST composite key includes txID (unique per Fabric tx), so without
	// this explicit idempotency lock, calling RecordDistribution twice for the
	// same holderHash+period would succeed and silently double-pay the holder.
	// Attack vector: admin error, replay, or race condition in the token-bridge.
	// Fix: write a DIST_LOCK~{holderHash}~{period} key before the DIST record;
	// reject any subsequent call for the same pair.
	lockKey, err := ctx.GetStub().CreateCompositeKey("DIST_LOCK", []string{holderHash, period})
	if err != nil {
		return "", fmt.Errorf("lock composite key: %w", err)
	}
	existingLock, err := ctx.GetStub().GetState(lockKey)
	if err != nil {
		return "", fmt.Errorf("lock key read: %w", err)
	}
	if existingLock != nil {
		return "", fmt.Errorf("distribution for holder %s… period %s already recorded — duplicate payment blocked",
			holderHash[:8], period)
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return "", fmt.Errorf("tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	// Write the idempotency lock FIRST so a crash between lock-write and record-write
	// leaves the lock set. On retry the caller sees ErrDuplicate and can inspect the
	// Fabric ledger to confirm whether the payment was actually dispatched.
	if err := ctx.GetStub().PutState(lockKey, []byte(txID)); err != nil {
		return "", fmt.Errorf("lock key write: %w", err)
	}

	rec := &DistributionRecord{
		HolderHash: holderHash,
		Amount:     amount,
		Period:     period,
		PaymentRef: paymentRef,
		RecordedAt: ts.Seconds,
		TxID:       txID,
	}
	// Composite key includes txID so each payout has a unique slot (append-only).
	key, err := ctx.GetStub().CreateCompositeKey("DIST", []string{holderHash, period, txID})
	if err != nil {
		return "", fmt.Errorf("composite key: %w", err)
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return "", fmt.Errorf("marshal: %w", err)
	}
	if err := ctx.GetStub().PutState(key, data); err != nil {
		return "", fmt.Errorf("put state: %w", err)
	}

	return txID, nil
}

// GetDistributionHistory returns all distribution records for a holder, ordered by composite key.
// Used for MiCA Art.71 holder statements and quarterly reconciliation.
// Returns an empty slice (not an error) when no records exist.
func (c *TokenDistributionContract) GetDistributionHistory(
	ctx contractapi.TransactionContextInterface,
	holderHash string,
) ([]*DistributionRecord, error) {
	if err := validateHash(holderHash); err != nil {
		return nil, fmt.Errorf("holderHash: %w", err)
	}

	iter, err := ctx.GetStub().GetStateByPartialCompositeKey("DIST", []string{holderHash})
	if err != nil {
		return nil, fmt.Errorf("partial key query: %w", err)
	}
	defer iter.Close()

	var records []*DistributionRecord
	for iter.HasNext() {
		result, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("iteration: %w", err)
		}
		var rec DistributionRecord
		if err := json.Unmarshal(result.Value, &rec); err != nil {
			return nil, fmt.Errorf("unmarshal: %w", err)
		}
		records = append(records, &rec)
	}
	return records, nil
}

// VerifyHolderConsent returns true if the holder has an active MiCA distribution consent.
// The token bridge calls this before every payout; RecordDistribution also enforces it.
func (c *TokenDistributionContract) VerifyHolderConsent(
	ctx contractapi.TransactionContextInterface,
	holderHash string,
) (bool, error) {
	if err := validateHash(holderHash); err != nil {
		return false, fmt.Errorf("holderHash: %w", err)
	}
	return c.holderHasConsent(ctx, holderHash)
}

// RecordHolderConsent writes or updates a holder's MiCA distribution consent.
// Called by the token bridge after the holder signs the MiCA Art.71 disclosure form.
// signatureTxHash must reference a channel-1 AdES record for legal binding.
// Revocation (granted=false) does not require a new signature.
func (c *TokenDistributionContract) RecordHolderConsent(
	ctx contractapi.TransactionContextInterface,
	holderHash string,
	granted bool,
	signatureTxHash string,
) (string, error) {
	if err := validateHash(holderHash); err != nil {
		return "", fmt.Errorf("holderHash: %w", err)
	}
	if granted && strings.TrimSpace(signatureTxHash) == "" {
		return "", fmt.Errorf("signatureTxHash is required when granting consent (MiCA Art.71 requires a signed disclosure)")
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return "", fmt.Errorf("tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &HolderConsent{
		HolderHash:      holderHash,
		Granted:         granted,
		SignatureTxHash: signatureTxHash,
		UpdatedAt:       ts.Seconds,
		TxID:            txID,
	}
	key, err := ctx.GetStub().CreateCompositeKey("HOLDER_CONSENT", []string{holderHash})
	if err != nil {
		return "", fmt.Errorf("composite key: %w", err)
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return "", fmt.Errorf("marshal: %w", err)
	}
	if err := ctx.GetStub().PutState(key, data); err != nil {
		return "", fmt.Errorf("put state: %w", err)
	}

	eventName := "HolderConsentRevoked"
	if granted {
		eventName = "HolderConsentGranted"
	}
	evtPayload, _ := json.Marshal(struct {
		HolderHash string `json:"holderHash"`
	}{HolderHash: holderHash})
	_ = ctx.GetStub().SetEvent(eventName, evtPayload)

	return txID, nil
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

func (c *TokenDistributionContract) holderHasConsent(
	ctx contractapi.TransactionContextInterface,
	holderHash string,
) (bool, error) {
	key, err := ctx.GetStub().CreateCompositeKey("HOLDER_CONSENT", []string{holderHash})
	if err != nil {
		return false, fmt.Errorf("composite key: %w", err)
	}
	data, err := ctx.GetStub().GetState(key)
	if err != nil {
		return false, fmt.Errorf("state read: %w", err)
	}
	if data == nil {
		return false, nil
	}
	var rec HolderConsent
	if err := json.Unmarshal(data, &rec); err != nil {
		return false, fmt.Errorf("unmarshal consent record: %w", err)
	}
	return rec.Granted, nil
}
