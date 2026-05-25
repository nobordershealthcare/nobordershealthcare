package code

import (
	"errors"
	"time"

	"github.com/nobordershealthcare/referral/internal/models"
)

// Sentinel errors returned by Validate.
var (
	ErrCodeInactive  = errors.New("referral code is inactive")
	ErrCodeExpired   = errors.New("referral code has expired")
	ErrUsageLimitHit = errors.New("referral code usage limit reached")
)

// nowFn is a hook for unit tests.
var nowFn = func() time.Time { return time.Now().UTC() }

// Validate checks whether a fetched ReferralCode may still be used.
// The caller is responsible for loading the code from the store first.
func Validate(rc *models.ReferralCode) error {
	if !rc.Active {
		return ErrCodeInactive
	}
	if rc.ExpiresAt != nil && nowFn().After(*rc.ExpiresAt) {
		return ErrCodeExpired
	}
	if rc.UsageLimit != -1 && rc.UsageCount >= rc.UsageLimit {
		return ErrUsageLimitHit
	}
	return nil
}
