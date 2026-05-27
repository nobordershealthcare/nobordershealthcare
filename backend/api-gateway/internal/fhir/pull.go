// pull.go — FHIR resource read endpoints for partner integrations.
//
// GET /v1/fhir/{resourceType}/{id}    — fetch single resource
// GET /v1/fhir/{resourceType}         — search resources (query params forwarded)
//
// Middleware chain mirrors push.go: key validation → rate limit → scope → consent → forward.
//
// Read scope matrix (by partner type):
//
//	pharmacy → AllergyIntolerance, MedicationStatement
//	dental   → AllergyIntolerance
//
// All other partner types have no defined read scope in v1.
// mental_health has write-only scope; reads of Condition are not permitted in v1.
package fhir

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"

	"github.com/redis/go-redis/v9"

	"github.com/nobordershealthcare/api-gateway/internal/billing"
	"github.com/nobordershealthcare/api-gateway/internal/partner"
)

// readScope maps partner type → set of readable FHIR resource types.
var readScope = map[partner.PartnerType]map[string]bool{
	partner.PartnerTypePharmacy: {
		"AllergyIntolerance":  true,
		"MedicationStatement": true,
	},
	partner.PartnerTypeDental: {
		"AllergyIntolerance": true,
	},
	// laboratory, radiology, mental_health, rehabilitation: no read scope in v1.
}

// PullHandler handles FHIR resource read requests from partners.
type PullHandler struct {
	rdb        *redis.Client
	akv        *partner.KeyValidator
	rl         *partner.RateLimiter
	cc         *ConsentChecker
	httpClient *http.Client
	meter      *billing.MeteringService
}

func NewPullHandler(
	rdb *redis.Client,
	akv *partner.KeyValidator,
	rl *partner.RateLimiter,
	cc *ConsentChecker,
	httpClient *http.Client,
) *PullHandler {
	return &PullHandler{
		rdb:        rdb,
		akv:        akv,
		rl:         rl,
		cc:         cc,
		httpClient: httpClient,
		meter:      billing.NewMeteringService(rdb),
	}
}

// Pull handles GET /v1/fhir/{resourceType}/{id}.
func (h *PullHandler) Pull(w http.ResponseWriter, r *http.Request) {
	h.serve(w, r, r.PathValue("resourceType"), r.PathValue("id"))
}

// Search handles GET /v1/fhir/{resourceType} (search — no id in path).
func (h *PullHandler) Search(w http.ResponseWriter, r *http.Request) {
	h.serve(w, r, r.PathValue("resourceType"), "")
}

func (h *PullHandler) serve(w http.ResponseWriter, r *http.Request, resourceType, resourceID string) {
	ctx := r.Context()

	// ── Step 1: API key validation ─────────────────────────────────────
	rawKey := r.Header.Get("X-API-Key")
	info, err := h.akv.Validate(ctx, rawKey)
	if err != nil {
		log.Printf("pull %s: key validation: %v", resourceType, err)
		httpJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid or missing API key"})
		return
	}

	// ── Step 2: rate limit ─────────────────────────────────────────────
	rlResult, err := h.rl.Allow(ctx, info.KeyHash, info.Tier)
	if err != nil {
		log.Printf("pull %s: rate limit (partner_hash=%s): %v", resourceType, info.KeyHash, err)
		httpJSON(w, http.StatusInternalServerError, map[string]string{"error": "rate limit service unavailable"})
		return
	}
	if !rlResult.Allowed {
		log.Printf("pull %s: rate limited partner_hash=%s window=%s", resourceType, info.KeyHash, rlResult.Window)
		httpJSON(w, http.StatusTooManyRequests, map[string]string{
			"error":  "rate limit exceeded",
			"window": rlResult.Window,
		})
		return
	}

	// ── Step 3: read scope check ───────────────────────────────────────
	if !canRead(info.Type, resourceType) {
		log.Printf("pull %s: scope denied partner_type=%s", resourceType, info.Type)
		httpJSON(w, http.StatusForbidden, map[string]string{
			"error": fmt.Sprintf("partner type %q is not permitted to read %q", info.Type, resourceType),
		})
		return
	}

	// ── Step 4: consent check ──────────────────────────────────────────
	patientHash := r.Header.Get("X-Patient-Hash")
	if patientHash == "" {
		httpJSON(w, http.StatusBadRequest, map[string]string{"error": "X-Patient-Hash header required"})
		return
	}

	consent, err := h.cc.Check(ctx, patientHash, info.Type, resourceType)
	if err != nil {
		log.Printf("pull %s: consent check (partner_hash=%s): %v", resourceType, info.KeyHash, err)
		httpJSON(w, http.StatusInternalServerError, map[string]string{"error": "consent service unavailable"})
		return
	}
	if !consent.Allowed {
		log.Printf("pull %s: consent denied partner_hash=%s: %s", resourceType, info.KeyHash, consent.DenialReason)
		httpJSON(w, http.StatusForbidden, map[string]string{"error": "patient consent not granted"})
		return
	}

	// ── Step 5: forward to normalization (mTLS) ────────────────────────
	upstreamResp, err := h.forwardRead(r, resourceType, resourceID, patientHash, info)
	if err != nil {
		log.Printf("pull %s: forward (partner_hash=%s): %v", resourceType, info.KeyHash, err)
		httpJSON(w, http.StatusBadGateway, map[string]string{"error": "upstream service unavailable"})
		return
	}
	defer upstreamResp.Body.Close()

	// ── Step 6: billing meter ──────────────────────────────────────────
	if err := h.meter.RecordCall(ctx, info.KeyHash); err != nil {
		log.Printf("pull %s: meter record (partner_hash=%s): %v", resourceType, info.KeyHash, err)
	}

	w.Header().Set("Content-Type", "application/fhir+json")
	w.WriteHeader(upstreamResp.StatusCode)
	_, _ = io.Copy(w, upstreamResp.Body)
}

// canRead returns true when partnerType is allowed to read resourceType.
func canRead(pt partner.PartnerType, resourceType string) bool {
	resources, ok := readScope[pt]
	if !ok {
		return false
	}
	return resources[resourceType]
}

func (h *PullHandler) forwardRead(
	r *http.Request,
	resourceType, resourceID, patientHash string,
	info *partner.PartnerKeyInfo,
) (*http.Response, error) {
	normURL := os.Getenv("NORMALIZATION_URL")
	if normURL == "" {
		normURL = "http://normalization.noborders.svc.cluster.local:8083"
	}

	var upURL string
	if resourceID != "" {
		upURL = fmt.Sprintf("%s/internal/fhir/%s/%s", normURL, resourceType, resourceID)
	} else {
		upURL = fmt.Sprintf("%s/internal/fhir/%s?%s", normURL, resourceType, r.URL.RawQuery)
	}

	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, upURL, nil)
	if err != nil {
		return nil, fmt.Errorf("build upstream request: %w", err)
	}
	req.Header.Set("X-Patient-Hash", patientHash)
	req.Header.Set("X-Partner-Type", string(info.Type))
	req.Header.Set("X-Partner-Hash", info.KeyHash)

	return h.httpClient.Do(req)
}
