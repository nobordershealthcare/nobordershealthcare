package diia

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
	"golang.org/x/crypto/sha3"
)

// signRequestTTL is the Redis TTL for pending signing requests.
// After 10 minutes the request is considered abandoned (Diia deeplinks
// are short-lived, and the patient's QR session is 15 min max).
const signRequestTTL = 10 * time.Minute

// signResultTTL is the Redis TTL for completed verification results.
// Kept long enough for the caller to poll; not indefinite (patient data hygiene).
const signResultTTL = 10 * time.Minute

// SignRequestMeta is persisted in Redis when a signing request is initiated.
// FileHashes stores SHA3-256(SHA-256 fileHash) — never the raw SHA-256 value.
// (The SHA-256 is only needed for the Diia API; we never persist it at rest.)
type SignRequestMeta struct {
	RequestID string    `json:"request_id"`
	BranchID  string    `json:"branch_id"`
	OfferID   string    `json:"offer_id"`
	FileKeys  []string  `json:"file_keys"`
	FileNames []string  `json:"file_names"`
	// FileHashes contains SHA3-256(fileHash) for each HashedFile, in the
	// same order as FileKeys. Never stores the raw SHA-256 file hash.
	FileHashes []string  `json:"file_hashes"` // SHA3-256(sha256_hash), hex
	CreatedAt  time.Time `json:"created_at"`
}

// VerifyResult is persisted after a callback signature verification.
type VerifyResult struct {
	RequestID string    `json:"request_id"`
	Verified  bool      `json:"verified"`
	// SignerHash is SHA3-256(signer certificate DER) — never cleartext identity.
	SignerHash  string    `json:"signer_hash,omitempty"`
	FileKey    string    `json:"file_key,omitempty"` // which file this result covers
	VerifiedAt time.Time `json:"verified_at"`
	ErrMsg     string    `json:"error,omitempty"` // non-empty on verification failure
}

// Store is the Redis-backed persistence layer for Diia signing requests and
// verification results. It never stores patient PII or raw cryptographic
// material — only SHA3-256 hashes.
type Store struct {
	rdb *redis.Client
}

// NewStore creates a Store backed by the provided Redis client.
func NewStore(rdb *redis.Client) *Store {
	return &Store{rdb: rdb}
}

// requestKey returns the Redis key for a pending sign request.
// Pattern: diia:sign:request:{requestID}
func requestKey(requestID string) string {
	return "diia:sign:request:" + requestID
}

// resultKey returns the Redis key for a completed verification result.
// Pattern: diia:sign:result:{requestID}
func resultKey(requestID string) string {
	return "diia:sign:result:" + requestID
}

// hashForStorage computes SHA3-256 of the given string and returns a 64-char
// lowercase hex digest. Used to wrap file SHA-256 digests before storing them
// in Redis so that raw SHA-256 values (external protocol data) never sit at rest.
func hashForStorage(s string) string {
	h := sha3.New256()
	h.Write([]byte(s))
	return hex.EncodeToString(h.Sum(nil))
}

// HashFileForStorage computes SHA3-256(sha256FileHash) for safe Redis storage.
// The sha256FileHash parameter is the hex string produced by HashFileSHA256.
// This wraps the SHA-256 hash in SHA3-256 so that raw SHA-256 values never
// sit in Redis at rest.
func HashFileForStorage(sha256FileHash string) string {
	return hashForStorage(sha256FileHash)
}

// SaveRequest stores a SignRequestMeta in Redis with signRequestTTL.
// The FileHashes in meta must already be SHA3-256 digests (not raw SHA-256).
// Use HashFileForStorage on each HashedFile.FileHash before building the meta.
func (s *Store) SaveRequest(ctx context.Context, meta SignRequestMeta) error {
	b, err := json.Marshal(meta)
	if err != nil {
		return fmt.Errorf("diia: store SaveRequest marshal: %w", err)
	}
	if err := s.rdb.Set(ctx, requestKey(meta.RequestID), b, signRequestTTL).Err(); err != nil {
		return fmt.Errorf("diia: store SaveRequest redis: %w", err)
	}
	return nil
}

// GetRequest retrieves a pending sign request by requestID.
// Returns (nil, nil) if the key does not exist (expired or unknown requestID).
func (s *Store) GetRequest(ctx context.Context, requestID string) (*SignRequestMeta, error) {
	b, err := s.rdb.Get(ctx, requestKey(requestID)).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("diia: store GetRequest redis: %w", err)
	}
	var meta SignRequestMeta
	if err := json.Unmarshal(b, &meta); err != nil {
		return nil, fmt.Errorf("diia: store GetRequest unmarshal: %w", err)
	}
	return &meta, nil
}

// SaveResult stores a VerifyResult in Redis with signResultTTL.
// The result may indicate success or failure — either is stored so that the
// caller can distinguish "not yet verified" (nil) from "verified false" (stored).
func (s *Store) SaveResult(ctx context.Context, result VerifyResult) error {
	b, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("diia: store SaveResult marshal: %w", err)
	}
	if err := s.rdb.Set(ctx, resultKey(result.RequestID), b, signResultTTL).Err(); err != nil {
		return fmt.Errorf("diia: store SaveResult redis: %w", err)
	}
	return nil
}

// GetResult retrieves a verification result by requestID.
// Returns (nil, nil) if the key does not exist (callback not yet received).
func (s *Store) GetResult(ctx context.Context, requestID string) (*VerifyResult, error) {
	b, err := s.rdb.Get(ctx, resultKey(requestID)).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("diia: store GetResult redis: %w", err)
	}
	var result VerifyResult
	if err := json.Unmarshal(b, &result); err != nil {
		return nil, fmt.Errorf("diia: store GetResult unmarshal: %w", err)
	}
	return &result, nil
}

// ── Auth request / result storage ─────────────────────────────────────────

const authRequestTTL = 10 * time.Minute
const authResultTTL  = 10 * time.Minute

// AuthRequestMeta is persisted when a Diia.ID auth session is initiated.
type AuthRequestMeta struct {
	RequestID string    `json:"request_id"`
	BranchID  string    `json:"branch_id"`
	OfferID   string    `json:"offer_id"`
	CreatedAt time.Time `json:"created_at"`
}

// AuthResult is persisted after the Diia.ID auth callback is received.
// Identity fields are stored for the status endpoint; they are cleared after
// authResultTTL. RNOKPP is never stored plaintext — only the SHA3-256 hash
// and a masked display string ("••••••7890").
type AuthResult struct {
	RequestID   string    `json:"request_id"`
	Status      string    `json:"status"`              // "complete" | "failed"
	FirstName   string    `json:"first_name,omitempty"`
	Patronymic  string    `json:"patronymic,omitempty"`
	LastName    string    `json:"last_name,omitempty"`
	RNOKPPHash  string    `json:"rnokpp_hash,omitempty"` // SHA3-256("UA:"+rnokpp)
	RNOKPPMask  string    `json:"rnokpp_mask,omitempty"` // "••••••XXXX"
	CompletedAt time.Time `json:"completed_at,omitempty"`
	FailReason  string    `json:"fail_reason,omitempty"`
}

func authRequestKey(id string) string { return "diia:auth:request:" + id }
func authResultKey(id string) string  { return "diia:auth:result:" + id }

// Verify *Store implements AuthStoreInterface at compile time.
var _ AuthStoreInterface = (*Store)(nil)

// SaveAuthRequest stores an AuthRequestMeta with authRequestTTL.
func (s *Store) SaveAuthRequest(ctx context.Context, meta AuthRequestMeta) error {
	b, err := json.Marshal(meta)
	if err != nil {
		return fmt.Errorf("diia: store SaveAuthRequest marshal: %w", err)
	}
	if err := s.rdb.Set(ctx, authRequestKey(meta.RequestID), b, authRequestTTL).Err(); err != nil {
		return fmt.Errorf("diia: store SaveAuthRequest redis: %w", err)
	}
	return nil
}

// GetAuthRequest retrieves a pending auth request by requestID.
// Returns (nil, nil) if the key does not exist (expired or unknown).
func (s *Store) GetAuthRequest(ctx context.Context, requestID string) (*AuthRequestMeta, error) {
	b, err := s.rdb.Get(ctx, authRequestKey(requestID)).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("diia: store GetAuthRequest redis: %w", err)
	}
	var meta AuthRequestMeta
	if err := json.Unmarshal(b, &meta); err != nil {
		return nil, fmt.Errorf("diia: store GetAuthRequest unmarshal: %w", err)
	}
	return &meta, nil
}

// SaveAuthResult stores an AuthResult with authResultTTL.
func (s *Store) SaveAuthResult(ctx context.Context, result AuthResult) error {
	b, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("diia: store SaveAuthResult marshal: %w", err)
	}
	if err := s.rdb.Set(ctx, authResultKey(result.RequestID), b, authResultTTL).Err(); err != nil {
		return fmt.Errorf("diia: store SaveAuthResult redis: %w", err)
	}
	return nil
}

// GetAuthResult retrieves an auth result by requestID.
// Returns (nil, nil) if the key does not exist (callback not yet received).
func (s *Store) GetAuthResult(ctx context.Context, requestID string) (*AuthResult, error) {
	b, err := s.rdb.Get(ctx, authResultKey(requestID)).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("diia: store GetAuthResult redis: %w", err)
	}
	var result AuthResult
	if err := json.Unmarshal(b, &result); err != nil {
		return nil, fmt.Errorf("diia: store GetAuthResult unmarshal: %w", err)
	}
	return &result, nil
}

// DeleteAuthRequest removes the auth request from Redis (one-time use).
// Called immediately after the iOS client polls a terminal status (complete/failed)
// so that the requestId cannot be replayed to obtain identity data a second time.
func (s *Store) DeleteAuthRequest(ctx context.Context, requestID string) error {
	if err := s.rdb.Del(ctx, authRequestKey(requestID)).Err(); err != nil && err != redis.Nil {
		return fmt.Errorf("diia: store DeleteAuthRequest redis: %w", err)
	}
	return nil
}

// DeleteAuthResult removes the auth result from Redis (one-time use).
// Called together with DeleteAuthRequest when a terminal status is served.
func (s *Store) DeleteAuthResult(ctx context.Context, requestID string) error {
	if err := s.rdb.Del(ctx, authResultKey(requestID)).Err(); err != nil && err != redis.Nil {
		return fmt.Errorf("diia: store DeleteAuthResult redis: %w", err)
	}
	return nil
}
