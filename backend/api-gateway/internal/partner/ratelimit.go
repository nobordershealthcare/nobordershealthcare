// ratelimit.go — Redis sliding-window rate limiter for partner API keys.
//
// Rate limits per tier:
//
//	free:         1 000 / day,  10 / min
//	professional: 50 000 / day, 100 / min
//	enterprise:   unlimited,    1 000 / min   (daily cap bypassed)
//
// Implementation uses a Redis sorted set per (partnerKeyHash, window) pair.
// Each request adds a member with score = now-ms. Members older than the window
// are pruned atomically via the Lua script before counting.
//
// The partnerKeyHash (SHA3-256 hex) is used as the rate-limit identifier — never
// a name, email, or any other PII.
package partner

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// TierLimits holds the per-tier rate limit values.
type TierLimits struct {
	PerMinute int64 // requests per 60s window; -1 = unlimited
	PerDay    int64 // requests per 86400s window; -1 = unlimited
}

var tierLimitsMap = map[RateLimitTier]TierLimits{
	TierFree:         {PerMinute: 10, PerDay: 1000},
	TierProfessional: {PerMinute: 100, PerDay: 50000},
	TierEnterprise:   {PerMinute: 1000, PerDay: -1}, // daily unlimited
}

// RateLimiter enforces sliding-window limits using Redis sorted sets.
type RateLimiter struct {
	rdb    *redis.Client
	script *redis.Script
}

// slidingWindowLua atomically checks and records a request in the sliding window.
//
// KEYS[1] = sorted set key
// ARGV[1] = window size in milliseconds
// ARGV[2] = max requests in window; -1 = unlimited
// ARGV[3] = current timestamp in milliseconds (unique score)
// ARGV[4] = unique member string (prevents score collision for concurrent requests)
// Returns 1 (allowed) or 0 (denied).
const slidingWindowLua = `
local key    = KEYS[1]
local window = tonumber(ARGV[1])
local lim    = tonumber(ARGV[2])
local now    = tonumber(ARGV[3])
local member = ARGV[4]

redis.call('ZREMRANGEBYSCORE', key, 0, now - window)

if lim == -1 then
  redis.call('ZADD', key, now, member)
  redis.call('PEXPIRE', key, window + 1000)
  return 1
end

local cnt = redis.call('ZCARD', key)
if cnt < lim then
  redis.call('ZADD', key, now, member)
  redis.call('PEXPIRE', key, window + 1000)
  return 1
end
return 0
`

func NewRateLimiter(rdb *redis.Client) *RateLimiter {
	return &RateLimiter{
		rdb:    rdb,
		script: redis.NewScript(slidingWindowLua),
	}
}

// RateLimitResult carries the outcome of a rate-limit check.
type RateLimitResult struct {
	Allowed  bool
	Window   string // "minute" or "day"
	Exceeded bool   // true when denied
}

// Allow checks both the per-minute and per-day windows for the given key hash.
// Returns (result, nil) on success. Returns an error only on Redis failures.
func (rl *RateLimiter) Allow(ctx context.Context, keyHash string, tier RateLimitTier) (*RateLimitResult, error) {
	limits, ok := tierLimitsMap[tier]
	if !ok {
		limits = tierLimitsMap[TierFree] // safe default
	}

	nowMs := time.Now().UnixMilli()
	member := fmt.Sprintf("%d-%s", nowMs, keyHash[:8]) // short prefix for readability

	// Per-minute check
	minKey := fmt.Sprintf("rl:min:%s:%d", keyHash, nowMs/60000) // bucket per minute
	allowed, err := rl.check(ctx, minKey, 60_000, limits.PerMinute, nowMs, member)
	if err != nil {
		return nil, fmt.Errorf("rate limit minute check: %w", err)
	}
	if !allowed {
		return &RateLimitResult{Allowed: false, Window: "minute", Exceeded: true}, nil
	}

	// Per-day check (skip when unlimited)
	if limits.PerDay != -1 {
		dayKey := fmt.Sprintf("rl:day:%s:%d", keyHash, nowMs/86_400_000) // bucket per day
		allowed, err = rl.check(ctx, dayKey, 86_400_000, limits.PerDay, nowMs, member)
		if err != nil {
			return nil, fmt.Errorf("rate limit day check: %w", err)
		}
		if !allowed {
			return &RateLimitResult{Allowed: false, Window: "day", Exceeded: true}, nil
		}
	}

	return &RateLimitResult{Allowed: true}, nil
}

// check runs the sliding window Lua script and returns (allowed, error).
func (rl *RateLimiter) check(
	ctx context.Context,
	key string,
	windowMs, limit, nowMs int64,
	member string,
) (bool, error) {
	result, err := rl.script.Run(ctx, rl.rdb,
		[]string{key},
		windowMs,
		limit,
		nowMs,
		member,
	).Int64()
	if err != nil {
		return false, fmt.Errorf("sliding window script: %w", err)
	}
	return result == 1, nil
}
