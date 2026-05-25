package main

// RevenueAllocation records the total EURC revenue figure for one quarter.
// World-state key: REVENUE~{period}  (one record per period, immutable after write)
type RevenueAllocation struct {
	Period       string `json:"period"`       // "YYYY-QN", e.g. "2026-Q2"
	TotalRevenue string `json:"totalRevenue"` // micro-EURC integer string (1 EURC = 1 000 000); no floats
	AllocatedAt  int64  `json:"allocatedAt"`  // Fabric GetTxTimestamp seconds
	TxID         string `json:"txID"`
}

// DistributionRecord is one EURC payout to a single NBHC token holder.
// World-state key: DIST~{holderHash}~{period}~{txID}
// Partial-key query on holderHash returns full payout history for MiCA Art.71 statements.
type DistributionRecord struct {
	HolderHash string `json:"holderHash"` // SHA3-256(salt+holderAddress) — no PII
	Amount     string `json:"amount"`     // micro-EURC integer string
	Period     string `json:"period"`     // matches RevenueAllocation.Period
	PaymentRef string `json:"paymentRef"` // Stripe charge ID or on-chain tx hash
	RecordedAt int64  `json:"recordedAt"` // Fabric GetTxTimestamp
	TxID       string `json:"txID"`
}

// HolderConsent records whether a token holder has granted MiCA distribution consent.
// This is NOT health-data consent — it is the disclosure consent required by MiCA Art.71.
// World-state key: HOLDER_CONSENT~{holderHash}  (last-write-wins; revocation overwrites)
// signatureTxHash anchors consent to a channel-1 AdES record so it is legally binding.
type HolderConsent struct {
	HolderHash      string `json:"holderHash"`
	Granted         bool   `json:"granted"`         // false = revoked
	SignatureTxHash string `json:"signatureTxHash"` // channel-1 AdES txID (required when granting)
	UpdatedAt       int64  `json:"updatedAt"`       // Fabric GetTxTimestamp
	TxID            string `json:"txID"`
}
