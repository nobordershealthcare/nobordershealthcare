// Package admin provides the bulk-import admin dashboard and re-send endpoints.
// All stats use phone_hash (SHA3-256) — never plaintext phone numbers.
package admin

import (
	"context"
	"fmt"
)

// BatchStats is returned by GET /bulk/stats/{batch_id}.
// Used by Odoo dashboard and admin web UI.
type BatchStats struct {
	BatchID        string           `json:"batch_id"`
	Total          int              `json:"total"`
	Activated      int              `json:"activated"`
	Pending        int              `json:"pending"`
	Expired        int              `json:"expired"`
	FailedDelivery []FailedDelivery `json:"failed_delivery,omitempty"`
}

// FailedDelivery describes a single failed notification attempt.
// PhoneHash is SHA3-256(phone) — never the plaintext phone number.
type FailedDelivery struct {
	PhoneHash string `json:"phone_hash"` // SHA3-256(phone)
	Channel   string `json:"channel"`    // "sms"|"telegram"|"whatsapp"|"signal"|"viber"|"email"
	Reason    string `json:"reason"`
	Attempts  int    `json:"attempts"`
}

// ResendRequest is the body of POST /bulk/resend/{batch_id}.
// PhoneHashes: SHA3-256 hashes of phones to re-send to.
// Set to nil or "all_failed" sentinel to re-send all failed entries.
type ResendRequest struct {
	PhoneHashes []string `json:"phone_hashes,omitempty"` // SHA3-256 hashes
	AllFailed   bool     `json:"all_failed,omitempty"`
}

// GetBatchStats returns delivery telemetry for a batch.
// Fetches from Redis (TTL 30 days) with ScyllaDB fallback.
func GetBatchStats(ctx context.Context, batchID string) (*BatchStats, error) {
	if batchID == "" {
		return nil, fmt.Errorf("batchID is required")
	}
	stats, err := loadStatsFromCache(ctx, batchID)
	if err != nil {
		return nil, fmt.Errorf("batch %q not found: %w", batchID, err)
	}
	return stats, nil
}

// ResendFailed re-dispatches activation invitations for failed/pending entries.
// Rate-limited to 1000 SMS/minute and per-channel limits.
// Returns the count of entries queued for re-send.
func ResendFailed(ctx context.Context, batchID string, req ResendRequest) (int, error) {
	if batchID == "" {
		return 0, fmt.Errorf("batchID is required")
	}

	var phoneHashes []string
	if req.AllFailed {
		hashes, err := loadFailedPhoneHashes(ctx, batchID)
		if err != nil {
			return 0, fmt.Errorf("load failed entries: %w", err)
		}
		phoneHashes = hashes
	} else {
		phoneHashes = req.PhoneHashes
	}

	if len(phoneHashes) == 0 {
		return 0, nil
	}

	// Re-queue for dispatch — the dispatcher enforces rate limits.
	if err := enqueueResend(ctx, batchID, phoneHashes); err != nil {
		return 0, fmt.Errorf("enqueue resend: %w", err)
	}
	return len(phoneHashes), nil
}

// ─── Storage stubs (Redis + ScyllaDB) ────────────────────────────────────────

func loadStatsFromCache(_ context.Context, batchID string) (*BatchStats, error) {
	// TODO: GET bulk:stats:{batchID} from Redis; fallback to ScyllaDB aggregate query
	_ = batchID
	return &BatchStats{BatchID: batchID}, nil
}

func loadFailedPhoneHashes(_ context.Context, batchID string) ([]string, error) {
	// TODO: SELECT phone_hash FROM pending_profiles
	//       WHERE batch_id = ? AND status IN ('failed','pending')
	_ = batchID
	return nil, nil
}

func enqueueResend(_ context.Context, batchID string, phoneHashes []string) error {
	// TODO: LPUSH bulk:resend:{batchID} phoneHashes...
	// Dispatcher worker pops from the list and respects channel rate limits.
	_ = batchID
	_ = phoneHashes
	return nil
}
