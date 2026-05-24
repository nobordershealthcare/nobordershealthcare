// push.go — FHIR resource write endpoint for partner integrations.
//
// POST /v1/fhir/{resourceType}
//
// Middleware chain:
//  1. API key validation (X-API-Key header → SHA3-256 hash → partner lookup)
//  2. Rate limit check (sliding window, tier-based)
//  3. Scope check (partner type allowed to write this resource type)
//  4. Consent check (patient must have granted the appropriate consent)
//  5. Forward to normalization service via mTLS
//  6. Emit billing meter event
//
// Scope matrix (write permissions by partner type):
//
//	laboratory   → Observation, DiagnosticReport
//	pharmacy     → MedicationDispense
//	radiology    → ImagingStudy, DiagnosticReport
//	dental       → Procedure
//	mental_health → Condition  (requires sensitive consent; never in emergency scope)
//
// All mental_health writes are labeled "sensitive" in the blockchain audit trail.
// PII is never written to logs — only SHA3-256 hashes.
package fhir

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"

	"github.com/redis/go-redis/v9"

	"github.com/nobordershealthcare/api-gateway/internal/billing"
	"github.com/nobordershealthcare/api-gateway/internal/partner"
)

// writeScope maps partner type → set of writable FHIR resource types.
var writeScope = map[partner.PartnerType]map[string]bool{
	partner.PartnerTypeLaboratory: {
		"Observation":      true,
		"DiagnosticReport": true,
	},
	partner.PartnerTypePharmacy: {
		"MedicationDispense": true,
	},
	partner.PartnerTypeRadiology: {
		"ImagingStudy":     true,
		"DiagnosticReport": true,
	},
	partner.PartnerTypeDental: {
		"Procedure": true,
	},
	partner.PartnerTypeMentalHealth: {
		"Condition": true,
	},
	// PartnerTypeRehabilitation: no write scope defined in v1 spec; deny all.
}

// PushHandler handles FHIR resource write requests from partners.
type PushHandler struct {
	rdb        *redis.Client
	akv        *partner.KeyValidator
	rl         *partner.RateLimiter
	cc         *ConsentChecker
	httpClient *http.Client
	meter      *billing.MeteringService
}

func NewPushHandler(
	rdb *redis.Client,
	akv *partner.KeyValidator,
	rl *partner.RateLimiter,
	cc *ConsentChecker,
	httpClient *http.Client,
) *PushHandler {
	return &PushHandler{
		rdb:        rdb,
		akv:        akv,
		rl:         rl,
		cc:         cc,
		httpClient: httpClient,
		meter:      billing.NewMeteringService(rdb),
	}
}

// Push handles POST /v1/fhir/{resourceType}.
func (h *PushHandler) Push(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	resourceType := r.PathValue("resourceType")

	// ── Step 1: API key validation ─────────────────────────────────────
	rawKey := r.Header.Get("X-API-Key")
	info, err := h.akv.Validate(ctx, rawKey)
	if err != nil {
		log.Printf("push %s: key validation: %v", resourceType, err)
		httpJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid or missing API key"})
		return
	}

	// ── Step 2: rate limit ─────────────────────────────────────────────
	rlResult, err := h.rl.Allow(ctx, info.KeyHash, info.Tier)
	if err != nil {
		log.Printf("push %s: rate limit check (partner_hash=%s): %v", resourceType, info.KeyHash, err)
		httpJSON(w, http.StatusInternalServerError, map[string]string{"error": "rate limit service unavailable"})
		return
	}
	if !rlResult.Allowed {
		log.Printf("push %s: rate limited partner_hash=%s window=%s", resourceType, info.KeyHash, rlResult.Window)
		httpJSON(w, http.StatusTooManyRequests, map[string]string{
			"error":  "rate limit exceeded",
			"window": rlResult.Window,
		})
		return
	}

	// ── Step 3: scope check ────────────────────────────────────────────
	if !canWrite(info.Type, resourceType) {
		log.Printf("push %s: scope denied partner_type=%s", resourceType, info.Type)
		httpJSON(w, http.StatusForbidden, map[string]string{
			"error": fmt.Sprintf("partner type %q is not permitted to write %q", info.Type, resourceType),
		})
		return
	}

	// ── Step 4: consent check ──────────────────────────────────────────
	// The patient hash must be provided in the X-Patient-Hash header (64 hex chars,
	// SHA3-256 output computed by the caller). We do not accept raw patient IDs.
	patientHash := r.Header.Get("X-Patient-Hash")
	if patientHash == "" {
		httpJSON(w, http.StatusBadRequest, map[string]string{"error": "X-Patient-Hash header required"})
		return
	}

	consent, err := h.cc.Check(ctx, patientHash, info.Type, resourceType)
	if err != nil {
		log.Printf("push %s: consent check (partner_hash=%s): %v", resourceType, info.KeyHash, err)
		httpJSON(w, http.StatusInternalServerError, map[string]string{"error": "consent service unavailable"})
		return
	}
	if !consent.Allowed {
		log.Printf("push %s: consent denied partner_hash=%s: %s", resourceType, info.KeyHash, consent.DenialReason)
		httpJSON(w, http.StatusForbidden, map[string]string{"error": "patient consent not granted"})
		return
	}

	// ── Step 5: forward to normalization service (mTLS) ────────────────
	body, err := io.ReadAll(io.LimitReader(r.Body, 10<<20)) // 10 MB limit
	if err != nil {
		httpJSON(w, http.StatusBadRequest, map[string]string{"error": "failed to read request body"})
		return
	}

	upstreamResp, err := h.forwardToNormalization(r, resourceType, patientHash, info, consent.IsSensitive, body)
	if err != nil {
		log.Printf("push %s: normalization forward (partner_hash=%s): %v", resourceType, info.KeyHash, err)
		httpJSON(w, http.StatusBadGateway, map[string]string{"error": "upstream service unavailable"})
		return
	}
	defer upstreamResp.Body.Close()

	// ── Step 6: billing meter ──────────────────────────────────────────
	if err := h.meter.RecordCall(ctx, info.KeyHash); err != nil {
		// Non-fatal — log and continue; billing is reconciled from Redis.
		log.Printf("push %s: meter record (partner_hash=%s): %v", resourceType, info.KeyHash, err)
	}

	// Proxy the upstream response back to the caller.
	w.Header().Set("Content-Type", "application/fhir+json")
	w.WriteHeader(upstreamResp.StatusCode)
	_, _ = io.Copy(w, upstreamResp.Body)
}

// canWrite returns true when partnerType is allowed to write resourceType.
func canWrite(pt partner.PartnerType, resourceType string) bool {
	resources, ok := writeScope[pt]
	if !ok {
		return false
	}
	return resources[resourceType]
}

// forwardToNormalization proxies the FHIR resource write to the normalization service.
// isSensitive=true (mental_health) causes the request to carry a header that tells
// the normalization service to label the Fabric channel-3 audit record as "sensitive".
func (h *PushHandler) forwardToNormalization(
	r *http.Request,
	resourceType, patientHash string,
	info *partner.PartnerKeyInfo,
	isSensitive bool,
	body []byte,
) (*http.Response, error) {
	normURL := os.Getenv("NORMALIZATION_URL")
	if normURL == "" {
		normURL = "https://normalization:8083"
	}

	upURL := fmt.Sprintf("%s/internal/fhir/%s", normURL, resourceType)
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, upURL, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("build upstream request: %w", err)
	}
	req.Header.Set("Content-Type", "application/fhir+json")
	req.Header.Set("X-Patient-Hash", patientHash)
	req.Header.Set("X-Partner-Type", string(info.Type))
	req.Header.Set("X-Partner-Hash", info.KeyHash) // safe: is a hash
	if isSensitive {
		req.Header.Set("X-Audit-Label", "sensitive")
	}

	return h.httpClient.Do(req)
}

func httpJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
