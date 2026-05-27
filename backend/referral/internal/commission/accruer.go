package commission

import (
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/nobordershealthcare/referral/internal/models"
)

// Accrue computes one period's CommissionAccrual for a conversion and
// the revenue amount received in that period.
// Returns nil without error for credit-based types (individual, provider).
func Accrue(
	conv *models.ReferralConversion,
	revenueEUR float64,
	period string, // "YYYY-MM"
	accrualTime time.Time,
) (*models.CommissionAccrual, error) {
	rate := Rate(conv, accrualTime)
	if rate == 0.0 {
		return nil, nil // credit-based — handled separately
	}

	amount := revenueEUR * rate
	if amount <= 0 {
		return nil, fmt.Errorf("computed commission amount non-positive: %.4f", amount)
	}

	return &models.CommissionAccrual{
		ID:               uuid.New().String(),
		ConversionID:     conv.ID,
		Period:           period,
		RevenueAmount:    revenueEUR,
		CommissionAmount: amount,
		ReferrerHash:     conv.ReferrerHash,
		StripeAccountID:  conv.StripeAccountID,
		Status:           models.StatusPending,
	}, nil
}
