// Package distribution calculates and orchestrates quarterly EURC distributions
// for NBHC token holders.  Pro-rata shares are computed using big.Int arithmetic
// (amounts in micro-EURC, 1 EURC = 1_000_000) to eliminate floating-point drift.
package distribution

import (
	"context"
	"fmt"
	"log"
	"math/big"
	"strconv"

	"github.com/ethereum/go-ethereum/common"

	"github.com/nobordershealthcare/token-bridge/internal/fabric"
	"github.com/nobordershealthcare/token-bridge/internal/payment"
	"github.com/nobordershealthcare/token-bridge/internal/polygon"
)

// HolderShare is the computed allocation for one holder before payment dispatch.
type HolderShare struct {
	Address    common.Address
	HolderHash string
	Balance    *big.Int // raw token units
	ShareMicro *big.Int // micro-EURC (1 EURC = 1_000_000)
}

// Calculator orchestrates the quarterly distribution cycle.
type Calculator struct {
	poly    *polygon.Listener
	fab     *fabric.Client
	pay     *payment.Dispatcher
	genesis uint64 // Polygon block to start replaying from (NBHC contract deploy block)
}

// New creates a Calculator.  genesis is the Polygon block number at which the
// NBHC token contract was deployed — used to replay Transfer events efficiently.
func New(poly *polygon.Listener, fab *fabric.Client, pay *payment.Dispatcher, genesis uint64) *Calculator {
	return &Calculator{poly: poly, fab: fab, pay: pay, genesis: genesis}
}

// RunQuarterlyDistribution executes the full distribution cycle for period (e.g. "2026-Q2"):
//  1. Verify that a revenue allocation has been recorded on Fabric for this period.
//  2. Enumerate all current token holders from Polygon Transfer event history.
//  3. Fetch each holder's current balance; filter out zero-balance and no-consent addresses.
//  4. Calculate pro-rata micro-EURC shares (integer arithmetic, no floats).
//  5. Dispatch payments via the payment.Dispatcher and record each payout on Fabric.
//
// Partial failures are logged but do not abort the run — the Fabric ledger acts as
// the reconciliation source of truth (missing records = unpaid holders to retry).
func (c *Calculator) RunQuarterlyDistribution(ctx context.Context, period string) error {
	log.Printf("token-bridge/distribution: starting %s distribution cycle", period)

	// 1. Load revenue allocation
	alloc, err := c.fab.GetRevenueAllocation(period)
	if err != nil {
		return fmt.Errorf("no revenue allocation for %s — run RecordRevenueAllocation first: %w", period, err)
	}
	totalMicro, ok := new(big.Int).SetString(alloc.TotalRevenue, 10)
	if !ok || totalMicro.Sign() <= 0 {
		return fmt.Errorf("invalid totalRevenue %q in allocation for %s", alloc.TotalRevenue, period)
	}
	log.Printf("token-bridge/distribution: %s total revenue = %s µEURC", period, alloc.TotalRevenue)

	// 2. Get total supply
	totalSupply, err := c.poly.GetTotalSupply(ctx)
	if err != nil {
		return fmt.Errorf("fetch total supply: %w", err)
	}
	if totalSupply.Sign() == 0 {
		return fmt.Errorf("total supply is zero — nothing to distribute")
	}

	// 3. Enumerate all holders from Transfer history
	allAddrs, err := c.poly.GetAllHoldersFromLogs(ctx, c.genesis)
	if err != nil {
		return fmt.Errorf("enumerate holders: %w", err)
	}
	log.Printf("token-bridge/distribution: %d candidate holders from Transfer history", len(allAddrs))

	// 4. Build shares
	shares, err := c.buildShares(ctx, allAddrs, totalSupply, totalMicro)
	if err != nil {
		return fmt.Errorf("build shares: %w", err)
	}
	log.Printf("token-bridge/distribution: %d eligible holders after consent + balance filter", len(shares))

	// 5. Dispatch and record
	var errs []error
	for _, s := range shares {
		if err := c.dispatchAndRecord(ctx, s, period); err != nil {
			log.Printf("token-bridge/distribution: ERROR holder %s period %s: %v", s.HolderHash[:8], period, err)
			errs = append(errs, err)
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("%s distribution completed with %d errors (see logs for details)", period, len(errs))
	}
	log.Printf("token-bridge/distribution: %s distribution complete — %d payouts", period, len(shares))
	return nil
}

// SyncNewHolder registers a holder discovered from a live Transfer event.
// It only writes a consent record placeholder if the holder has never appeared on Fabric.
// Actual consent must be recorded via the app's MiCA disclosure flow.
func (c *Calculator) SyncNewHolder(ctx context.Context, evt polygon.HolderEvent) {
	// A VerifyHolderConsent call is enough to check existence; false just means no consent yet.
	_, err := c.fab.VerifyHolderConsent(evt.HolderHash)
	if err != nil {
		log.Printf("token-bridge/distribution: WARNING cannot check consent for %s: %v", evt.HolderHash[:8], err)
	}
	// We intentionally do NOT write a default consent record here.
	// MiCA Art.71 requires a positive opt-in via the signed disclosure form.
	log.Printf("token-bridge/distribution: new holder %s synced (consent pending MiCA disclosure)", evt.HolderHash[:8])
}

// ─── Internal ─────────────────────────────────────────────────────────────────

// buildShares fetches balances and consent for each address, computes pro-rata
// micro-EURC allocations, and returns only eligible holders.
func (c *Calculator) buildShares(
	ctx context.Context,
	addrs []common.Address,
	totalSupply *big.Int,
	totalMicro *big.Int,
) ([]HolderShare, error) {
	shares := make([]HolderShare, 0, len(addrs))

	for _, addr := range addrs {
		holderHash := c.poly.HashHolder(addr)

		// Consent gate
		ok, err := c.fab.VerifyHolderConsent(holderHash)
		if err != nil {
			log.Printf("token-bridge/distribution: consent check failed for %s: %v (skipping)", holderHash[:8], err)
			continue
		}
		if !ok {
			continue // no MiCA consent — cannot distribute
		}

		// Current balance
		bal, err := c.poly.GetBalance(ctx, addr)
		if err != nil {
			log.Printf("token-bridge/distribution: balance fetch failed for %s: %v (skipping)", holderHash[:8], err)
			continue
		}
		if bal.Sign() == 0 {
			continue // no current holdings
		}

		// Pro-rata share = (balance * totalMicro) / totalSupply  [integer, truncated]
		share := new(big.Int).Mul(bal, totalMicro)
		share.Div(share, totalSupply)

		if share.Sign() == 0 {
			continue // rounds to zero — skip to avoid dust payouts
		}

		shares = append(shares, HolderShare{
			Address:    addr,
			HolderHash: holderHash,
			Balance:    bal,
			ShareMicro: share,
		})
	}

	return shares, nil
}

func (c *Calculator) dispatchAndRecord(ctx context.Context, s HolderShare, period string) error {
	amountStr := s.ShareMicro.String()

	// Dispatch payment — returns the external reference (Stripe charge ID / on-chain txHash)
	payRef, err := c.pay.Dispatch(ctx, payment.Request{
		HolderHash:     s.HolderHash,
		HolderAddress:  s.Address,
		AmountMicroEUR: s.ShareMicro,
		Period:         period,
	})
	if err != nil {
		return fmt.Errorf("payment dispatch: %w", err)
	}

	// Record the payout on Fabric (chaincode re-checks consent as a guard)
	txID, err := c.fab.RecordDistribution(s.HolderHash, amountStr, period, payRef)
	if err != nil {
		// Payment was dispatched but Fabric write failed — log with full details for manual reconciliation.
		return fmt.Errorf("payment dispatched (ref=%s) but Fabric record failed: %w", payRef, err)
	}

	log.Printf("token-bridge/distribution: paid %s µEURC → %s… (payRef=%s, fabricTx=%s)",
		amountStr, s.HolderHash[:8], payRef, txID)
	return nil
}

// MicroToEURC converts a micro-EURC big.Int to a human-readable decimal string.
// Used only for log messages — never for on-chain values.
func MicroToEURC(micro *big.Int) string {
	euros := new(big.Int).Div(micro, big.NewInt(1_000_000))
	remainder := new(big.Int).Mod(micro, big.NewInt(1_000_000))
	return strconv.FormatInt(euros.Int64(), 10) + "." +
		fmt.Sprintf("%06d", remainder.Int64()) + " EURC"
}
