// metering.go — API call metering and usage reporting for billing.
//
// Every successful FHIR push or pull increments two Redis counters:
//   - meter:day:{partnerKeyHash}:{YYYY-MM-DD}   — daily count (TTL 90 days)
//   - meter:month:{partnerKeyHash}:{YYYY-MM}    — monthly count (TTL 13 months)
//
// The partner's key hash (SHA3-256 hex) is used as the billing identifier —
// never a name or email (which are PII).
//
// UsageHandler (GET /v1/billing/usage) returns aggregated usage for the caller's
// own key. PartnerUsageHandler (GET /v1/billing/usage/{partnerID}) is admin-only.
//
// Month-end sync to Odoo is triggered by the OdooSyncMonthly cron (called externally
// by the normalization service scheduler or a Kubernetes CronJob).
package billing

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/nobordershealthcare/api-gateway/internal/partner"
)

const (
	meterDayTTL   = 90 * 24 * time.Hour   // daily buckets retained 90 days
	meterMonthTTL = 395 * 24 * time.Hour  // monthly buckets retained ~13 months
)

// MeteringService records and retrieves API call counts.
type MeteringService struct {
	rdb *redis.Client
}

func NewMeteringService(rdb *redis.Client) *MeteringService {
	return &MeteringService{rdb: rdb}
}

// RecordCall increments the daily and monthly counters for the given key hash.
// keyHash must be the SHA3-256 hex of the partner's raw key — never the raw key itself.
func (m *MeteringService) RecordCall(ctx context.Context, keyHash string) error {
	now := time.Now().UTC()
	dayKey := fmt.Sprintf("meter:day:%s:%s", keyHash, now.Format("2006-01-02"))
	monthKey := fmt.Sprintf("meter:month:%s:%s", keyHash, now.Format("2006-01"))

	pipe := m.rdb.TxPipeline()
	pipe.Incr(ctx, dayKey)
	pipe.Expire(ctx, dayKey, meterDayTTL)
	pipe.Incr(ctx, monthKey)
	pipe.Expire(ctx, monthKey, meterMonthTTL)

	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("meter record: %w", err)
	}
	return nil
}

// DailyCount returns the call count for the given key hash on the given date.
func (m *MeteringService) DailyCount(ctx context.Context, keyHash string, day time.Time) (int64, error) {
	key := fmt.Sprintf("meter:day:%s:%s", keyHash, day.UTC().Format("2006-01-02"))
	val, err := m.rdb.Get(ctx, key).Int64()
	if err != nil {
		if err == redis.Nil {
			return 0, nil
		}
		return 0, fmt.Errorf("daily count: %w", err)
	}
	return val, nil
}

// MonthlyCount returns the call count for the given key hash in the given month.
func (m *MeteringService) MonthlyCount(ctx context.Context, keyHash string, month time.Time) (int64, error) {
	key := fmt.Sprintf("meter:month:%s:%s", keyHash, month.UTC().Format("2006-01"))
	val, err := m.rdb.Get(ctx, key).Int64()
	if err != nil {
		if err == redis.Nil {
			return 0, nil
		}
		return 0, fmt.Errorf("monthly count: %w", err)
	}
	return val, nil
}

// UsageResponse is the JSON payload returned by usage endpoints.
type UsageResponse struct {
	KeyHash    string  `json:"key_hash"`    // safe identifier — SHA3-256 hex
	Today      int64   `json:"today"`
	ThisMonth  int64   `json:"this_month"`
	LastMonth  int64   `json:"last_month"`
}

// UsageHandler handles GET /v1/billing/usage.
// Authenticates via X-API-Key header and returns the caller's own usage.
func (m *MeteringService) UsageHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	rawKey := r.Header.Get("X-API-Key")
	if rawKey == "" {
		httpJSON(w, http.StatusUnauthorized, map[string]string{"error": "X-API-Key required"})
		return
	}
	kh := partner.HashRawKey(rawKey)

	usage, err := m.buildUsageResponse(ctx, kh)
	if err != nil {
		log.Printf("usage handler (key_hash=%s): %v", kh, err)
		httpJSON(w, http.StatusInternalServerError, map[string]string{"error": "usage lookup failed"})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(usage)
}

// PartnerUsageHandler handles GET /v1/billing/usage/{partnerID} (admin endpoint).
// Looks up the key hash from the partner record and returns usage.
func (m *MeteringService) PartnerUsageHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	partnerID := r.PathValue("partnerID")
	if partnerID == "" {
		httpJSON(w, http.StatusBadRequest, map[string]string{"error": "missing partnerID"})
		return
	}

	akv := partner.NewKeyValidator(m.rdb)
	p, err := akv.LoadPartner(ctx, partnerID)
	if err != nil {
		httpJSON(w, http.StatusNotFound, map[string]string{"error": "partner not found"})
		return
	}

	usage, err := m.buildUsageResponse(ctx, p.KeyHash)
	if err != nil {
		log.Printf("partner usage (id=%s key_hash=%s): %v", partnerID, p.KeyHash, err)
		httpJSON(w, http.StatusInternalServerError, map[string]string{"error": "usage lookup failed"})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(usage)
}

func (m *MeteringService) buildUsageResponse(ctx context.Context, kh string) (*UsageResponse, error) {
	now := time.Now().UTC()

	today, err := m.DailyCount(ctx, kh, now)
	if err != nil {
		return nil, err
	}
	thisMonth, err := m.MonthlyCount(ctx, kh, now)
	if err != nil {
		return nil, err
	}
	lastMonth, err := m.MonthlyCount(ctx, kh, now.AddDate(0, -1, 0))
	if err != nil {
		return nil, err
	}

	return &UsageResponse{
		KeyHash:   kh,
		Today:     today,
		ThisMonth: thisMonth,
		LastMonth: lastMonth,
	}, nil
}

// OdooSyncMonthly syncs the previous month's call totals to Odoo for all active partners.
// Called by an external CronJob at the start of each month.
func (m *MeteringService) OdooSyncMonthly(ctx context.Context, partnerIDs []string) {
	prevMonth := time.Now().UTC().AddDate(0, -1, 0)
	odoo, err := partner.NewOdooClient()
	if err != nil {
		log.Printf("odoo monthly sync: client: %v", err)
		return
	}

	akv := partner.NewKeyValidator(m.rdb)
	for _, pid := range partnerIDs {
		p, err := akv.LoadPartner(ctx, pid)
		if err != nil {
			log.Printf("odoo monthly sync: load partner %s: %v", pid, err)
			continue
		}
		calls, err := m.MonthlyCount(ctx, p.KeyHash, prevMonth)
		if err != nil {
			log.Printf("odoo monthly sync: count partner %s: %v", pid, err)
			continue
		}
		if err := odoo.SyncMonthlyCalls(pid, int(calls), prevMonth); err != nil {
			log.Printf("odoo monthly sync: sync partner %s: %v", pid, err)
		}
	}
}

func httpJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
