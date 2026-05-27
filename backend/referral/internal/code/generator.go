// Package code handles referral code generation and validation.
package code

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	"golang.org/x/crypto/sha3"

	"github.com/nobordershealthcare/referral/internal/models"
)

// SHA3256Hex returns the lowercase hex SHA3-256 digest of input.
// All referrer/referred identifiers MUST be pre-salted before hashing here.
func SHA3256Hex(input string) string {
	h := sha3.New256()
	h.Write([]byte(input))
	return hex.EncodeToString(h.Sum(nil))
}

// randomUpperHex returns n random bytes as uppercase hex (2n chars).
func randomUpperHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("rng read: %w", err)
	}
	return strings.ToUpper(hex.EncodeToString(b)), nil
}

// Generate creates a new ReferralCode for the caller.
//
// referrerHash must already be SHA3-256(salt+referrerID) — never pass a raw ID.
// stripeAccountID is only required for partner and affiliate types.
func Generate(referrerHash string, rtype models.ReferralType, stripeAccountID string) (*models.ReferralCode, error) {
	if len(referrerHash) != 64 {
		return nil, fmt.Errorf("referrerHash must be 64-char SHA3-256 hex, got %d", len(referrerHash))
	}

	suffix, err := randomUpperHex(32) // 64 uppercase hex chars — 256-bit random (was 2 bytes / 16-bit)
	if err != nil {
		return nil, err
	}

	hashPrefix := strings.ToUpper(referrerHash[:6])

	var prefix string
	var usageLimit int
	switch rtype {
	case models.TypeIndividual:
		prefix = "NBH"
		usageLimit = 10
	case models.TypePartner:
		prefix = "PART"
		usageLimit = -1
	case models.TypeAffiliate:
		prefix = "AFF"
		usageLimit = -1
	case models.TypeProvider:
		prefix = "PROV"
		usageLimit = -1
	default:
		return nil, fmt.Errorf("unknown referral type: %q", rtype)
	}

	code := fmt.Sprintf("%s-%s-%s", prefix, hashPrefix, suffix)
	codeHash := SHA3256Hex(code)

	return &models.ReferralCode{
		Code:            code,
		CodeHash:        codeHash,
		ReferrerHash:    referrerHash,
		ReferralType:    rtype,
		StripeAccountID: stripeAccountID,
		CreatedAt:       time.Now().UTC(),
		UsageCount:      0,
		UsageLimit:      usageLimit,
		Active:          true,
	}, nil
}
