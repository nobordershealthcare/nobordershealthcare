// Package commission calculates and accrues referral commissions.
package commission

import (
	"time"

	"github.com/nobordershealthcare/referral/internal/models"
)

// Rate returns the applicable commission rate for a conversion at the given
// accrual time. For affiliate types the rate steps down over subscription age.
// Individual and provider types return 0.0 — they earn credits, not revenue share.
func Rate(conv *models.ReferralConversion, accrualTime time.Time) float64 {
	switch conv.ReferralType {
	case models.TypePartner:
		return 0.15 // 15% lifetime

	case models.TypeAffiliate:
		months := monthsSince(conv.ConvertedAt, accrualTime)
		return affiliateRate(months)

	default:
		// individual → free month credit; provider → API credits
		return 0.0
	}
}

// affiliateRate returns the tier rate based on subscription age in months.
//
//	months  1-12 → 20%
//	months 13-24 → 10%
//	months 25+   →  5%
func affiliateRate(months int) float64 {
	switch {
	case months <= 12:
		return 0.20
	case months <= 24:
		return 0.10
	default:
		return 0.05
	}
}

// monthsSince returns the number of whole calendar months elapsed
// between start and end (minimum 1 to avoid month-0 edge cases).
func monthsSince(start, end time.Time) int {
	years := end.Year() - start.Year()
	months := int(end.Month()) - int(start.Month())
	total := years*12 + months
	if total < 1 {
		return 1
	}
	return total
}
