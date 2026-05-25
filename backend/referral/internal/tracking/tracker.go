// Package tracking implements attribution chain recording and fraud prevention.
package tracking

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	velocityWindow = time.Hour
	velocityLimit  = 5 // conversions/hour before code is paused
)

// ErrSelfReferral is returned when the referrer and referred hashes match.
// selfReferral detection is mandatory — a user must not earn from their own signup.
var ErrSelfReferral = errors.New("self-referral rejected: referrerHash == referredHash")

// Tracker performs Redis-backed fraud checks and attribution recording.
type Tracker struct {
	rdb *redis.Client
}

// New creates a Tracker backed by the supplied Redis client.
func New(rdb *redis.Client) *Tracker {
	return &Tracker{rdb: rdb}
}

// CheckSelfReferral returns ErrSelfReferral when both SHA3-256 hashes match.
// Must be called before recording any conversion.
func (t *Tracker) CheckSelfReferral(referrerHash, referredHash string) error {
	// selfReferral guard — same hash means same user attempted to refer themselves
	if referrerHash == referredHash {
		return ErrSelfReferral
	}
	return nil
}

// CheckVelocity increments the per-code hourly counter and returns true if
// the code exceeds the velocity limit. The caller should pause the code.
func (t *Tracker) CheckVelocity(ctx context.Context, codeHash string) (bool, error) {
	key := fmt.Sprintf("vel:%s", codeHash)
	count, err := t.rdb.Incr(ctx, key).Result()
	if err != nil {
		return false, fmt.Errorf("velocity INCR: %w", err)
	}
	if count == 1 {
		// Set expiry on first increment only.
		t.rdb.Expire(ctx, key, velocityWindow) //nolint:errcheck
	}
	return count > velocityLimit, nil
}

// FlagForReview marks a code as requiring manual review (same-device heuristic).
// The referral proceeds but the accrual is held pending review.
func (t *Tracker) FlagForReview(ctx context.Context, codeHash, deviceToken string) {
	key := fmt.Sprintf("review:%s:%s", codeHash, deviceToken)
	if err := t.rdb.Set(ctx, key, "1", 72*time.Hour).Err(); err != nil {
		log.Printf("[tracking] FlagForReview redis error codeHash=%.8s: %v", codeHash, err)
	}
}

// RecordFirstTouch stores the first-touch code for a referred user in Redis.
// If a first-touch already exists, it is preserved (first touch wins).
func (t *Tracker) RecordFirstTouch(ctx context.Context, referredHash, codeHash string) error {
	key := fmt.Sprintf("ft:%s", referredHash)
	// SETNX — only sets if not already present
	ok, err := t.rdb.SetNX(ctx, key, codeHash, 365*24*time.Hour).Result()
	if err != nil {
		return fmt.Errorf("RecordFirstTouch SETNX: %w", err)
	}
	if !ok {
		log.Printf("[tracking] first touch already recorded for referredHash=%.8s", referredHash)
	}
	return nil
}

// GetFirstTouch returns the first code hash seen for a referred user, or "".
func (t *Tracker) GetFirstTouch(ctx context.Context, referredHash string) (string, error) {
	key := fmt.Sprintf("ft:%s", referredHash)
	val, err := t.rdb.Get(ctx, key).Result()
	if errors.Is(err, redis.Nil) {
		return "", nil
	}
	return val, err
}
