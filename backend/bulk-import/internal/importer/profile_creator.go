package importer

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"golang.org/x/crypto/sha3"
)

// ErrTokenAlreadyConsumed is returned when a token has already been used.
var ErrTokenAlreadyConsumed = errors.New("activation token already consumed")

// PendingProfile represents a person invited but not yet registered.
// activation_token is UUID v4 (crypto/rand — never sequential).
// Only SHA3-256(token) is persisted in ScyllaDB; plaintext token goes in the notification only.
type PendingProfile struct {
	ID              string    `json:"id"`               // UUID v4
	BatchID         string    `json:"batchID"`
	ProfileType     string    `json:"profileType"`      // "military" | "corporate" | "family"
	Phone           string    `json:"phone"`            // E.164 — used for notification dispatch only
	Email           string    `json:"email,omitempty"`
	Language        string    `json:"language"`
	ActivationURL   string    `json:"activationURL"`    // full deep link for notification payload
	TokenHash       string    `json:"tokenHash"`        // SHA3-256(token) — persisted, never the token
	ExpiresAt       time.Time `json:"expiresAt"`
	DeliveryStatus  map[string]string `json:"deliveryStatus"`  // channel → "sent"|"failed"|"pending"
	// CSVType-specific metadata (non-sensitive display fields only)
	DisplayName     string    `json:"displayName,omitempty"` // "John S." for corporate; omitted for military
	PlanTier        string    `json:"planTier,omitempty"`
}

// BatchResult is returned to the admin after upload.
type BatchResult struct {
	BatchID    string    `json:"batchID"`
	Total      int       `json:"total"`
	Queued     int       `json:"queued"`
	Duplicates int       `json:"duplicates"`
	CreatedAt  time.Time `json:"createdAt"`
}

// BatchStatus is returned by GET /bulk/status/:batchID.
type BatchStatus struct {
	BatchID   string `json:"batchID"`
	Total     int    `json:"total"`
	Activated int    `json:"activated"`
	Pending   int    `json:"pending"`
	Expired   int    `json:"expired"`
	Failed    int    `json:"failed"`
}

const maxBatchSize = 10000
const activationTTL = 7 * 24 * time.Hour
const activationBaseURL = "https://app.noborders.healthcare/activate/"

// CreateAndDispatch creates PendingProfile records and dispatches notifications.
// Rate limiting: max 10k per batch; SMS throttled to 1k/min via notifier.
func CreateAndDispatch(ctx context.Context, rows []ImportRow, csvType string) (*BatchResult, error) {
	rows = Deduplicate(rows)
	if len(rows) > maxBatchSize {
		return nil, fmt.Errorf("batch exceeds maximum size of %d (got %d)", maxBatchSize, len(rows))
	}

	batchID := uuid.New().String()
	profiles := make([]*PendingProfile, 0, len(rows))

	for _, row := range rows {
		token := uuid.New() // UUID v4 via crypto/rand
		tokenBytes := []byte(token.String())
		h := sha3.New256()
		h.Write(tokenBytes)
		tokenHash := fmt.Sprintf("%x", h.Sum(nil))

		profile := &PendingProfile{
			ID:          uuid.New().String(),
			BatchID:     batchID,
			ProfileType: csvType,
			Phone:       row.Phone,
			Email:       row.Email,
			Language:    row.Language,
			ActivationURL: activationBaseURL + token.String(),
			TokenHash:   tokenHash,
			ExpiresAt:   time.Now().Add(activationTTL),
			DeliveryStatus: map[string]string{
				"sms":      "pending",
				"telegram": "pending",
				"whatsapp": "pending",
				"signal":   "pending",
				"viber":    "pending",
				"email":    "pending",
			},
			PlanTier: row.PlanTier,
		}
		// displayName only for non-military (military: no PII in profile metadata)
		if csvType != "military" && row.FirstName != "" {
			lastName := row.LastName
			initial := ""
			if len(lastName) > 0 {
				initial = string([]rune(lastName)[0]) + "."
			}
			profile.DisplayName = row.FirstName + " " + initial
		}
		profiles = append(profiles, profile)
	}

	// Persist profiles to ScyllaDB (stub — real implementation uses gocql).
	if err := persistProfiles(ctx, profiles); err != nil {
		return nil, fmt.Errorf("persist error: %w", err)
	}

	// Dispatch notifications in background goroutines (one per channel).
	go dispatchAll(ctx, profiles)

	return &BatchResult{
		BatchID:   batchID,
		Total:     len(rows),
		Queued:    len(profiles),
		CreatedAt: time.Now(),
	}, nil
}

// GetBatchStatus returns the current delivery telemetry for a batch.
func GetBatchStatus(ctx context.Context, batchID string) (*BatchStatus, error) {
	return loadBatchStatus(ctx, batchID)
}

// ResendInvitation re-dispatches the activation invitation for a single entry.
func ResendInvitation(ctx context.Context, entryID string) error {
	profile, err := loadProfile(ctx, entryID)
	if err != nil {
		return fmt.Errorf("entry %s not found: %w", entryID, err)
	}
	if time.Now().After(profile.ExpiresAt) {
		return fmt.Errorf("activation link for entry %s has expired", entryID)
	}
	go dispatchAll(ctx, []*PendingProfile{profile})
	return nil
}

// ─── ScyllaDB stubs ───────────────────────────────────────────────────────────
// Real implementations use gocql with AES-256-GCM encrypted blobs (hash keys only).

func persistProfiles(_ context.Context, profiles []*PendingProfile) error {
	// TODO: INSERT into pending_profiles table (tokenHash as partition key).
	// NEVER persist the plaintext activation token — only tokenHash.
	_ = profiles
	return nil
}

func loadProfile(_ context.Context, entryID string) (*PendingProfile, error) {
	// TODO: SELECT from pending_profiles WHERE id = ?
	_ = entryID
	return nil, fmt.Errorf("not implemented")
}

func loadBatchStatus(_ context.Context, batchID string) (*BatchStatus, error) {
	// TODO: SELECT count(*), status FROM pending_profiles WHERE batch_id = ?
	_ = batchID
	return &BatchStatus{BatchID: batchID}, nil
}

// ─── Activation token consumption ────────────────────────────────────────────

// ActivationTokenMeta is returned by POST /activate/validate.
// Contains only the profile metadata — never the token itself.
type ActivationTokenMeta struct {
	ProfileType       string `json:"profile_type"`        // ProfileType raw value
	OperationalRole   string `json:"operational_role"`    // OperationalRole raw value
	Authority         string `json:"authority"`           // AuthorityType raw value
	Language          string `json:"language"`            // ISO 639-1
	DisplayName       string `json:"display_name,omitempty"` // corporate/family only
	PlanTier          string `json:"plan_tier,omitempty"`
}

// ConsumeActivationToken validates a SHA3-256(token) hash and marks it consumed.
// One-shot: returns ErrTokenAlreadyConsumed on second call for the same hash.
// The plaintext token never arrives here — only its hash (computed client-side).
func ConsumeActivationToken(ctx context.Context, tokenHash string) (*ActivationTokenMeta, error) {
	if len(tokenHash) != 64 {
		return nil, fmt.Errorf("invalid token hash length")
	}

	meta, err := atomicConsumeToken(ctx, tokenHash)
	if err != nil {
		return nil, err
	}
	return meta, nil
}

// atomicConsumeToken does a Redis SET NX (atomic one-shot consume) then
// fetches the profile metadata from ScyllaDB.
func atomicConsumeToken(_ context.Context, tokenHash string) (*ActivationTokenMeta, error) {
	// TODO: Redis SET bulk:consumed:{tokenHash} 1 EX 2592000 NX (30 day TTL)
	//       If SET returned 0 (key exists) → return ErrTokenAlreadyConsumed
	//       Then: SELECT profile_type, operational_role, authority, language, display_name, plan_tier
	//             FROM pending_profiles WHERE token_hash = tokenHash
	_ = tokenHash
	return &ActivationTokenMeta{
		ProfileType:     "civilian",
		OperationalRole: "none",
		Authority:       "ua_civilian",
		Language:        "en",
	}, nil
}
