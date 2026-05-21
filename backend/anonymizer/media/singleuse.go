package media

import (
	"context"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
	"golang.org/x/crypto/sha3"
)

const minioTokenTTL = 120 * time.Second

// luaConsume atomically reads and deletes the single-use key.
// Returns the stored value on first call, nil on any subsequent call.
// The GET+DEL in a single Lua script eliminates any TOCTOU window —
// two concurrent requests for the same URL cannot both get a non-nil result.
const luaConsume = `
local v = redis.call('GET', KEYS[1])
if not v then return nil end
redis.call('DEL', KEYS[1])
return v
`

// SingleUseStore enforces that each pre-signed MinIO URL is consumed at most once.
// It uses the same Redis Cluster client as token/redis.go but operates on a
// separate key namespace (minio:used:{...}).
type SingleUseStore struct {
	client        *redis.ClusterClient
	consumeScript *redis.Script
}

func NewSingleUseStore(addrs []string) *SingleUseStore {
	client := redis.NewClusterClient(&redis.ClusterOptions{Addrs: addrs})
	return &SingleUseStore{
		client:        client,
		consumeScript: redis.NewScript(luaConsume),
	}
}

// Register issues a single-use token for urlPath+nonce and stores it in Redis
// with a 120-second TTL. Must be called immediately after GenerateURL.
// Returns the opaque registration key to pass back to the caller as proof
// (used by the /internal/consume endpoint to identify the URL).
func (s *SingleUseStore) Register(ctx context.Context, urlPath, nonce string) (string, error) {
	key := s.registrationKey(urlPath, nonce)
	ttlSec := fmt.Sprintf("%d", int(minioTokenTTL.Seconds()))

	script := redis.NewScript(`
local ok = redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2], 'NX')
if ok then return 1 end
return 0
`)
	result, err := script.Run(ctx, s.client, []string{key}, "1", ttlSec).Int()
	if err != nil {
		return "", fmt.Errorf("redis register minio token: %w", err)
	}
	if result == 0 {
		return "", fmt.Errorf("minio token already registered for this url+nonce")
	}
	return key, nil
}

// Consume atomically reads and deletes the single-use key.
// Returns nil on first call (URL is now consumed), ErrAlreadyConsumed on
// any subsequent call or if the TTL has expired.
//
// This is called by the /internal/consume endpoint (port :8081, loopback only).
// That endpoint MUST NOT be exposed outside the pod network — Istio
// NetworkPolicy enforces this in infra/.
func (s *SingleUseStore) Consume(ctx context.Context, registrationKey string) error {
	result, err := s.consumeScript.Run(ctx, s.client, []string{registrationKey}).Result()
	if err == redis.Nil {
		return ErrAlreadyConsumed
	}
	if err != nil {
		return fmt.Errorf("redis consume minio token: %w", err)
	}
	// Lua returns the stored value ("1") as a bulk string on first consume.
	str, ok := result.(string)
	if !ok || subtle.ConstantTimeCompare([]byte(str), []byte("1")) != 1 {
		return ErrAlreadyConsumed
	}
	return nil
}

// registrationKey derives the Redis key for a URL by hashing urlPath+nonce
// with SHA3-256. This keeps the raw URL path out of Redis keys.
func (s *SingleUseStore) registrationKey(urlPath, nonce string) string {
	h := sha3.Sum256([]byte(urlPath + nonce))
	return "minio:used:{" + hex.EncodeToString(h[:]) + "}"
}

var ErrAlreadyConsumed = fmt.Errorf("url already consumed or expired")

// Ping checks Redis connectivity.
func (s *SingleUseStore) Ping(ctx context.Context) error {
	return s.client.Ping(ctx).Err()
}
