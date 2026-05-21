package token

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	// SessionTokenTTL is the TTL for session → cassandra_key mappings.
	SessionTokenTTL = 300 * time.Second

	// MaxTTL caps any TTL accepted from callers.
	MaxTTL = 300 * time.Second
)

// luaSetNX atomically sets key=value with an EX TTL only if the key does
// not already exist. Returns 1 on success, 0 if the key was already present
// (collision or replay attempt).
//
// NX = only if Not eXists — prevents token reuse at the Redis level.
// EX = TTL in seconds.
// All keys for a single request carry the same hash tag {uuid} so they
// land on the same Redis Cluster slot, keeping the Lua call cross-slot-safe.
const luaSetNX = `
local ok = redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2], 'NX')
if ok then return 1 end
return 0
`

// luaGetDel atomically reads and deletes a key in one script.
// Returns the value if found, nil if the key was absent or already consumed.
// Used for single-use enforcement (MinIO tokens and session tokens on consume).
const luaGetDel = `
local v = redis.call('GET', KEYS[1])
if not v then return nil end
redis.call('DEL', KEYS[1])
return v
`

// Store wraps a Redis Cluster client with token-specific operations.
type Store struct {
	client    *redis.ClusterClient
	setScript *redis.Script
	getScript *redis.Script
}

// NewStore returns a Store connected to the Redis Cluster at addrs.
func NewStore(addrs []string) *Store {
	client := redis.NewClusterClient(&redis.ClusterOptions{
		Addrs: addrs,
	})
	return &Store{
		client:    client,
		setScript: redis.NewScript(luaSetNX),
		getScript: redis.NewScript(luaGetDel),
	}
}

// Set stores token→cassandraKey with the given TTL using the NX Lua script.
// Returns ErrTokenExists if the key already exists (replay or collision).
// The cassandraKey value is NEVER logged — do not add logging of it here.
func (s *Store) Set(ctx context.Context, token string, cassandraKey []byte, ttl time.Duration) error {
	if ttl > MaxTTL {
		ttl = MaxTTL
	}
	key := clusterKey(token)
	ttlSec := fmt.Sprintf("%d", int(ttl.Seconds()))

	result, err := s.setScript.Run(ctx, s.client, []string{key}, cassandraKey, ttlSec).Int()
	if err != nil {
		return fmt.Errorf("redis set token: %w", err)
	}
	if result == 0 {
		return ErrTokenExists
	}
	return nil
}

// Consume atomically reads and deletes the token, returning the cassandraKey.
// Returns ErrTokenNotFound if the token is absent or already consumed.
// Safe for concurrent callers — the Lua GET+DEL is atomic, no TOCTOU window.
func (s *Store) Consume(ctx context.Context, token string) ([]byte, error) {
	key := clusterKey(token)
	result, err := s.getScript.Run(ctx, s.client, []string{key}).Result()
	if err == redis.Nil {
		return nil, ErrTokenNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("redis consume token: %w", err)
	}
	// Lua returns a bulk string; go-redis delivers it as a Go string.
	str, ok := result.(string)
	if !ok {
		return nil, fmt.Errorf("redis consume: unexpected result type")
	}
	return []byte(str), nil
}

// Ping checks Redis connectivity.
func (s *Store) Ping(ctx context.Context) error {
	return s.client.Ping(ctx).Err()
}

// clusterKey wraps the token in a hash tag so all keys for one request
// land on the same Redis Cluster slot.
func clusterKey(token string) string {
	return "anon:{" + token + "}"
}

var (
	ErrTokenExists   = fmt.Errorf("token already exists")
	ErrTokenNotFound = fmt.Errorf("token not found or already consumed")
)
