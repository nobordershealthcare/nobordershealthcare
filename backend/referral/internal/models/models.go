// Package models defines shared data types for the referral service.
// No PII is stored — all user identifiers are SHA3-256 hashes.
package models

import "time"

// ReferralType enumerates the four referral programme tiers.
type ReferralType string

const (
	TypeIndividual ReferralType = "individual" // patient → friend, account credit
	TypePartner    ReferralType = "partner"    // clinic/hospital, 15% lifetime
	TypeAffiliate  ReferralType = "affiliate"  // broker, 20→10→5% tiered
	TypeProvider   ReferralType = "provider"   // lab/pharmacy, API credits
)

// Conversion / accrual status values.
const (
	StatusPending   = "pending"
	StatusApproved  = "approved"
	StatusPaid      = "paid"
	StatusFailed    = "failed"
	StatusCancelled = "cancelled"
	StatusFlagged   = "flagged"
)

// CommissionType distinguishes cash payouts from credit grants.
const (
	CommissionTypeRevShare = "revenue_share" // partner / affiliate
	CommissionTypeCredit   = "credit"        // individual free month / provider API credits
)

// Payout minimum thresholds in euro-cents.
const (
	MinPayoutPartnerCents   = 5000  // €50
	MinPayoutAffiliateCents = 10000 // €100
)

// APICreditsPerActivation is the provider reward per activated patient.
const APICreditsPerActivation = 1000

// ReferralCode represents a shareable code in the programme.
// CodeHash (SHA3-256) is stored; Code itself is returned to the caller only.
type ReferralCode struct {
	Code            string       // NBH-/PART-/AFF-/PROV- prefix + hash6 + random4
	CodeHash        string       // SHA3-256(code) — persisted identifier
	ReferrerHash    string       // SHA3-256(salt+referrerID)
	ReferralType    ReferralType
	StripeAccountID string     // Stripe Connect account (partner/affiliate only)
	CreatedAt       time.Time
	ExpiresAt       *time.Time // nil = no expiry
	UsageCount      int
	UsageLimit      int  // 10 for individual, -1 = unlimited
	Active          bool
}

// ReferralConversion records a successful referral activation.
type ReferralConversion struct {
	ID              string
	CodeHash        string
	ReferrerHash    string
	ReferredHash    string       // SHA3-256(salt+referredID) — no PII
	ReferralType    ReferralType // copied from ReferralCode at conversion time
	StripeAccountID string       // Stripe Connect account for payouts
	ConvertedAt     time.Time
	SubscriptionID  string  // Stripe subscription ID
	PlanTier        string
	CommissionRate  float64 // initial rate: 0.15 / 0.20 / 0.0
	CommissionType  string  // CommissionTypeRevShare | CommissionTypeCredit
	Status          string
}

// CommissionAccrual is one month's earned commission for a conversion.
type CommissionAccrual struct {
	ID               string
	ConversionID     string
	Period           string     // "2026-05" YYYY-MM
	RevenueAmount    float64    // what the subscriber paid (EUR)
	CommissionAmount float64    // what the referrer earns (EUR)
	ReferrerHash     string
	StripeAccountID  string
	Status           string
	PaidAt           *time.Time
	StripeTxID       string
}

// ReferralStats is the response payload for GET /referral/stats/{referrer_hash}.
type ReferralStats struct {
	TotalConversions  int     `json:"total_conversions"`
	PendingCommission float64 `json:"pending_commission"`
	PaidCommission    float64 `json:"paid_commission"`
	ActiveReferred    int     `json:"active_referred"`
	CreditsEarned     int     `json:"credits_earned"`
}
