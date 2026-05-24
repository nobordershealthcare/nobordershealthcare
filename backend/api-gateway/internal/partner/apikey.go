// apikey.go — API key types, generation, hashing, and validation.
//
// Key format: nbhc_{partnerType}_{base64url(32 random bytes)}
// Storage invariant: SHA3-256(rawKey) is persisted; the raw key bytes are NEVER written
// to any store, log, or metric. The raw key is returned ONCE (at generation / rotation)
// and must be transmitted to the partner over TLS and never logged.
//
// SHA3-256 is used per project hashing standard (golang.org/x/crypto/sha3).
package partner

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
	"golang.org/x/crypto/sha3"
)

// PartnerType identifies the healthcare partner category.
type PartnerType string

const (
	PartnerTypeLaboratory     PartnerType = "laboratory"
	PartnerTypePharmacy       PartnerType = "pharmacy"
	PartnerTypeRadiology      PartnerType = "radiology"
	PartnerTypeDental         PartnerType = "dental"
	PartnerTypeRehabilitation PartnerType = "rehabilitation"
	PartnerTypeMentalHealth   PartnerType = "mental_health"
)

// validPartnerTypes is the allowlist for incoming type strings.
var validPartnerTypes = map[PartnerType]bool{
	PartnerTypeLaboratory:     true,
	PartnerTypePharmacy:       true,
	PartnerTypeRadiology:      true,
	PartnerTypeDental:         true,
	PartnerTypeRehabilitation: true,
	PartnerTypeMentalHealth:   true,
}

func (t PartnerType) Valid() bool { return validPartnerTypes[t] }

// RateLimitTier governs the sliding-window rate limits applied to a partner.
type RateLimitTier string

const (
	TierFree         RateLimitTier = "free"
	TierProfessional RateLimitTier = "professional"
	TierEnterprise   RateLimitTier = "enterprise"
)

// PartnerStatus tracks the lifecycle of a partner registration.
type PartnerStatus string

const (
	StatusPending   PartnerStatus = "pending"
	StatusApproved  PartnerStatus = "approved"
	StatusSuspended PartnerStatus = "suspended"
	StatusRevoked   PartnerStatus = "revoked"
)

// Partner is the full partner record persisted in Redis.
type Partner struct {
	ID           string        `json:"id"`
	Name         string        `json:"name"`
	Organization string        `json:"organization"`
	Email        string        `json:"email"`
	Type         PartnerType   `json:"type"`
	FHIRVersion  string        `json:"fhir_version"`
	Tier         RateLimitTier `json:"tier"`
	Status       PartnerStatus `json:"status"`
	KeyHash      string        `json:"key_hash"`   // SHA3-256 hex of the raw key
	CreatedAt    time.Time     `json:"created_at"`
	ApprovedAt   *time.Time    `json:"approved_at,omitempty"`
	OdooID       int           `json:"odoo_id,omitempty"`
}

// PartnerKeyInfo is the subset of partner data decoded from a validated key.
// KeyHash is safe to log (it is a hash, never the raw key).
type PartnerKeyInfo struct {
	PartnerID string
	Type      PartnerType
	Tier      RateLimitTier
	Status    PartnerStatus
	KeyHash   string // log-safe identifier: SHA3-256 hex
}

// Redis key layout:
//
//	partner:rec:{id}      — Partner JSON
//	partner:idx:kh:{hash} — partnerID indexed by key hash
const (
	prefixPartnerRec = "partner:rec:"
	prefixKeyHashIdx = "partner:idx:kh:"
)

// GenerateKeyPair creates a new API key pair.
// Returns (rawKey, keyHash, error).
//
//   - rawKey   — the credential string to deliver to the partner; format:
//     nbhc_{type}_{base64url(32 random bytes)}
//   - keyHash  — hex(SHA3-256(rawKey)); the ONLY value persisted
//
// The entropy buffer is zeroed before this function returns.
// Callers must transmit rawKey to the partner over TLS and discard it immediately;
// it cannot be recovered once this function returns.
func GenerateKeyPair(pt PartnerType) (rawKey string, keyHash string, err error) {
	var entropy [32]byte
	if _, err = rand.Read(entropy[:]); err != nil {
		return "", "", fmt.Errorf("generate key entropy: %w", err)
	}
	rawKey = "nbhc_" + string(pt) + "_" + base64.RawURLEncoding.EncodeToString(entropy[:])

	// Hash before zeroing entropy — rawKey holds the only copy now.
	keyHash = HashRawKey(rawKey)

	// Zero entropy — rawKey is now the only copy in this stack frame.
	for i := range entropy {
		entropy[i] = 0
	}
	return rawKey, keyHash, nil
}

// HashRawKey computes hex(SHA3-256(rawKey)).
// This is the storage representation — the raw key is NEVER persisted.
func HashRawKey(rawKey string) string {
	digest := sha3.Sum256([]byte(rawKey))
	return hex.EncodeToString(digest[:])
}

// KeyValidator resolves an API key string to a PartnerKeyInfo via the Redis hash index.
type KeyValidator struct {
	rdb *redis.Client
}

func NewKeyValidator(rdb *redis.Client) *KeyValidator {
	return &KeyValidator{rdb: rdb}
}

// Validate extracts and validates the API key from the HTTP header value.
// The raw key is hashed immediately; only the hash travels further in the system.
// Returns PartnerKeyInfo on success; error if the key is unknown, suspended, or revoked.
func (v *KeyValidator) Validate(ctx context.Context, rawKey string) (*PartnerKeyInfo, error) {
	if rawKey == "" {
		return nil, errors.New("missing API key")
	}

	// Hash immediately — raw key lives only in this stack frame.
	kh := HashRawKey(rawKey)

	partnerID, err := v.rdb.Get(ctx, prefixKeyHashIdx+kh).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, errors.New("invalid API key")
		}
		return nil, fmt.Errorf("key lookup: %w", err)
	}

	p, err := v.LoadPartner(ctx, partnerID)
	if err != nil {
		return nil, fmt.Errorf("load partner record: %w", err)
	}

	if p.KeyHash != kh {
		// Stale index — key was rotated; reject.
		return nil, errors.New("invalid API key")
	}
	switch p.Status {
	case StatusSuspended:
		return nil, errors.New("partner suspended")
	case StatusRevoked:
		return nil, errors.New("partner revoked")
	case StatusPending:
		return nil, errors.New("partner not yet approved")
	}

	return &PartnerKeyInfo{
		PartnerID: p.ID,
		Type:      p.Type,
		Tier:      p.Tier,
		Status:    p.Status,
		KeyHash:   kh,
	}, nil
}

// LoadPartner fetches a Partner record by ID from Redis.
func (v *KeyValidator) LoadPartner(ctx context.Context, partnerID string) (*Partner, error) {
	raw, err := v.rdb.Get(ctx, prefixPartnerRec+partnerID).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, fmt.Errorf("partner %q not found", partnerID)
		}
		return nil, fmt.Errorf("partner record get: %w", err)
	}
	var p Partner
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		return nil, fmt.Errorf("partner record decode: %w", err)
	}
	return &p, nil
}

// SavePartner persists a Partner record to Redis (no expiry — partners are long-lived).
func SavePartner(ctx context.Context, rdb *redis.Client, p *Partner) error {
	data, err := json.Marshal(p)
	if err != nil {
		return fmt.Errorf("marshal partner: %w", err)
	}
	if err := rdb.Set(ctx, prefixPartnerRec+p.ID, data, 0).Err(); err != nil {
		return fmt.Errorf("save partner record: %w", err)
	}
	return nil
}

// IndexKeyHash writes the key-hash → partnerID secondary index.
// Call this after generating a new key or rotating a key.
func IndexKeyHash(ctx context.Context, rdb *redis.Client, kh, partnerID string) error {
	if err := rdb.Set(ctx, prefixKeyHashIdx+kh, partnerID, 0).Err(); err != nil {
		return fmt.Errorf("index key hash: %w", err)
	}
	return nil
}

// RemoveKeyHashIndex deletes the old key-hash index entry during key rotation.
func RemoveKeyHashIndex(ctx context.Context, rdb *redis.Client, oldKH string) error {
	return rdb.Del(ctx, prefixKeyHashIdx+oldKH).Err()
}
