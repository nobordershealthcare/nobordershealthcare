// Package payment dispatches EURC distributions to NBHC token holders.
// Supported rails:
//   - Stripe (SEPA bank transfer or Stripe EURC payout) for fiat-preference holders
//   - On-chain EURC transfer on Polygon for crypto-native holders
//
// The caller chooses the rail via the Request.Rail field.
// The returned string is the external payment reference stored on Fabric.
package payment

import (
	"context"
	"fmt"
	"log"
	"math/big"
	"os"
	"strconv"

	"github.com/ethereum/go-ethereum/common"
	stripe "github.com/stripe/stripe-go/v76"
	"github.com/stripe/stripe-go/v76/transfer"
)

// Rail selects the payment mechanism.
type Rail string

const (
	RailStripe  Rail = "stripe"   // Stripe SEPA transfer / EURC payout
	RailOnChain Rail = "onchain"  // Direct EURC ERC-20 transfer on Polygon
)

// Request carries all information needed to dispatch a single EURC payout.
type Request struct {
	HolderHash     string         // SHA3-256 — used only for logging (no PII)
	HolderAddress  common.Address // Polygon wallet address
	AmountMicroEUR *big.Int       // micro-EURC (1 EURC = 1_000_000)
	Period         string         // e.g. "2026-Q2"
	Rail           Rail           // defaults to RailStripe if zero-value
	// StripeDestination is the Stripe connected account or IBAN (for SEPA).
	// Required when Rail == RailStripe.
	StripeDestination string
}

// Dispatcher dispatches EURC payments and returns the external payment reference.
type Dispatcher struct {
	stripeKey    string
	eurcContract common.Address // Polygon EURC ERC-20 contract address
}

// New creates a Dispatcher.  stripeKey and eurcContractAddr are read from
// environment at startup — never hardcoded.
func New() *Dispatcher {
	d := &Dispatcher{
		stripeKey:    mustEnv("STRIPE_API_KEY"),
		eurcContract: common.HexToAddress(getenv("EURC_CONTRACT_ADDR", "")),
	}
	if d.eurcContract == (common.Address{}) {
		log.Printf("token-bridge/payment: EURC_CONTRACT_ADDR not set — on-chain rail unavailable; only Stripe rail will succeed")
	}
	return d
}

// Dispatch executes the payment for req and returns the external reference string.
// The reference is suitable for storage as DistributionRecord.PaymentRef on Fabric.
func (d *Dispatcher) Dispatch(ctx context.Context, req Request) (string, error) {
	if req.AmountMicroEUR == nil || req.AmountMicroEUR.Sign() <= 0 {
		return "", fmt.Errorf("dispatch: amount must be positive")
	}

	rail := req.Rail
	if rail == "" {
		rail = RailStripe
	}

	switch rail {
	case RailStripe:
		return d.dispatchStripe(ctx, req)
	case RailOnChain:
		return d.dispatchOnChain(ctx, req)
	default:
		return "", fmt.Errorf("unknown payment rail %q", rail)
	}
}

// ─── Stripe ───────────────────────────────────────────────────────────────────

// dispatchStripe sends a EURC payout via Stripe Transfers API.
// Amount is converted from micro-EURC to euro-cents (1 EURC = 100 euro-cents = 1_000_000 µEURC).
func (d *Dispatcher) dispatchStripe(_ context.Context, req Request) (string, error) {
	if req.StripeDestination == "" {
		return "", fmt.Errorf("StripeDestination is required for Stripe rail")
	}

	stripe.Key = d.stripeKey

	// micro-EURC → euro-cents: divide by 10_000 (1 EURC = 100 cents = 1_000_000 µEURC)
	cents := new(big.Int).Div(req.AmountMicroEUR, big.NewInt(10_000)).Int64()
	if cents == 0 {
		return "", fmt.Errorf("amount rounds to zero euro-cents — skip dust payout")
	}

	params := &stripe.TransferParams{
		Amount:      stripe.Int64(cents),
		Currency:    stripe.String("eur"),
		Destination: stripe.String(req.StripeDestination),
	}
	// SECURITY: Idempotency key prevents double-payment if the bridge crashes after
	// Stripe accepts the transfer but before Fabric records it. Stripe deduplicates
	// requests with the same key within 24h and returns the original transfer object.
	// M-01 fix: Key = holderHash:period:cents — includes amount so a recomputed
	// payout with a different figure generates a distinct key (no silent amount drift).
	params.SetIdempotencyKey(req.HolderHash + ":" + req.Period + ":" + strconv.FormatInt(cents, 10))
	params.AddMetadata("period", req.Period)
	params.AddMetadata("holder_hash", req.HolderHash)   // no PII — only the hash
	params.AddMetadata("source", "nbh-token-bridge")

	t, err := transfer.New(params)
	if err != nil {
		return "", fmt.Errorf("stripe transfer: %w", err)
	}

	log.Printf("token-bridge/payment: stripe transfer %s for holder %s period %s",
		t.ID, req.HolderHash[:8], req.Period)
	return t.ID, nil
}

// ─── On-chain EURC ────────────────────────────────────────────────────────────

// dispatchOnChain is a stub for direct EURC ERC-20 transfers on Polygon.
// Full implementation requires a hot wallet (or Fireblocks/Gnosis Safe integration)
// and is tracked in the token-bridge backlog.
func (d *Dispatcher) dispatchOnChain(_ context.Context, req Request) (string, error) {
	if d.eurcContract == (common.Address{}) {
		return "", fmt.Errorf("EURC_CONTRACT_ADDR not configured — on-chain rail unavailable")
	}

	// TODO: sign and broadcast EURC ERC-20 transfer from the bridge treasury wallet.
	// Return the on-chain tx hash as the payment reference.
	return "", fmt.Errorf("on-chain EURC rail: not yet implemented (Polygon EURC addr=%s)", d.eurcContract.Hex())
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func mustEnv(key string) string {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		panic(fmt.Sprintf("token-bridge/payment: required env var %s is not set", key))
	}
	return v
}

func getenv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}
