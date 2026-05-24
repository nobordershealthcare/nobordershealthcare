// registration.go — Partner registration and approval HTTP handlers.
//
// POST /v1/partners/register   — submit a new partner application (status: pending)
// POST /v1/partners/{id}/approve — approve and activate (generates key pair)
// POST /v1/partners/{id}/keys/rotate — rotate key (invalidates old key hash)
// GET  /v1/partners/{id}       — fetch partner record
//
// Key generation follows the invariant in apikey.go:
//   raw key → returned to caller ONCE, never logged or stored.
//   key hash (SHA3-256) → persisted in Redis + synced to Odoo.
package partner

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// RegistrationRequest is the JSON body for POST /v1/partners/register.
type RegistrationRequest struct {
	Name         string        `json:"name"`
	Organization string        `json:"organization"`
	Email        string        `json:"email"`
	Type         PartnerType   `json:"type"`
	FHIRVersion  string        `json:"fhir_version"`
}

func (r *RegistrationRequest) validate() error {
	if r.Name == "" {
		return errors.New("name required")
	}
	if r.Organization == "" {
		return errors.New("organization required")
	}
	if r.Email == "" {
		return errors.New("email required")
	}
	if !r.Type.Valid() {
		return fmt.Errorf("invalid partner type %q", r.Type)
	}
	if r.FHIRVersion == "" {
		r.FHIRVersion = "R4"
	}
	return nil
}

// ApprovalRequest is the JSON body for POST /v1/partners/{id}/approve.
type ApprovalRequest struct {
	Tier   RateLimitTier `json:"tier"`    // default: free
	OdooID int           `json:"odoo_id"` // Odoo res.partner id (optional at approval time)
}

// KeyResponse is returned when a raw key is issued or rotated.
// The raw_key field is the ONLY opportunity for the caller to capture the credential.
// It is never stored and cannot be recovered.
type KeyResponse struct {
	PartnerID string `json:"partner_id"`
	KeyHash   string `json:"key_hash"`   // SHA3-256 hex — safe to log / store
	RawKey    string `json:"raw_key"`    // the actual credential — log never, transmit once
}

// RegistrationHandler serves partner lifecycle endpoints.
type RegistrationHandler struct {
	rdb *redis.Client
	akv *KeyValidator
}

func NewRegistrationHandler(rdb *redis.Client, akv *KeyValidator) *RegistrationHandler {
	return &RegistrationHandler{rdb: rdb, akv: akv}
}

// Register handles POST /v1/partners/register.
func (h *RegistrationHandler) Register(w http.ResponseWriter, r *http.Request) {
	var req RegistrationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, "invalid JSON body", http.StatusBadRequest)
		return
	}
	if err := req.validate(); err != nil {
		httpError(w, err.Error(), http.StatusBadRequest)
		return
	}

	ctx := r.Context()
	p := Partner{
		ID:           uuid.New().String(),
		Name:         req.Name,
		Organization: req.Organization,
		Email:        req.Email,
		Type:         req.Type,
		FHIRVersion:  req.FHIRVersion,
		Tier:         TierFree,
		Status:       StatusPending,
		CreatedAt:    time.Now().UTC(),
	}

	if err := SavePartner(ctx, h.rdb, &p); err != nil {
		log.Printf("register partner: save: %v", err)
		httpError(w, "failed to save partner", http.StatusInternalServerError)
		return
	}

	// Log only the non-PII identifier — never name, email, or organization.
	log.Printf("partner registration received: id=%s type=%s", p.ID, p.Type)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"partner_id": p.ID,
		"status":     string(StatusPending),
	})
}

// Approve handles POST /v1/partners/{id}/approve.
// Generates a key pair and returns the raw key ONCE.
func (h *RegistrationHandler) Approve(w http.ResponseWriter, r *http.Request) {
	partnerID := r.PathValue("id")
	if partnerID == "" {
		httpError(w, "missing partner id", http.StatusBadRequest)
		return
	}

	var req ApprovalRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, "invalid JSON body", http.StatusBadRequest)
		return
	}
	if req.Tier == "" {
		req.Tier = TierFree
	}

	ctx := r.Context()
	p, err := h.akv.LoadPartner(ctx, partnerID)
	if err != nil {
		httpError(w, "partner not found", http.StatusNotFound)
		return
	}
	if p.Status != StatusPending {
		httpError(w, fmt.Sprintf("partner status is %q, expected %q", p.Status, StatusPending), http.StatusConflict)
		return
	}

	// Generate key pair — raw key lives only in this scope; hash is persisted.
	rawKey, kh, err := GenerateKeyPair(p.Type)
	if err != nil {
		log.Printf("approve partner %s: key gen failed: %v", partnerID, err)
		httpError(w, "key generation failed", http.StatusInternalServerError)
		return
	}

	now := time.Now().UTC()
	p.Status = StatusApproved
	p.Tier = req.Tier
	p.KeyHash = kh
	p.ApprovedAt = &now
	if req.OdooID > 0 {
		p.OdooID = req.OdooID
	}

	if err := SavePartner(ctx, h.rdb, p); err != nil {
		log.Printf("approve partner %s: save: %v", partnerID, err)
		httpError(w, "failed to save partner", http.StatusInternalServerError)
		return
	}
	if err := IndexKeyHash(ctx, h.rdb, kh, partnerID); err != nil {
		log.Printf("approve partner %s: index key hash: %v", partnerID, err)
		httpError(w, "failed to index key", http.StatusInternalServerError)
		return
	}

	// Odoo sync — non-blocking; log failure but do not fail the response.
	go syncApprovalToOdoo(p)

	log.Printf("partner approved: id=%s type=%s tier=%s key_hash=%s", partnerID, p.Type, p.Tier, kh)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(KeyResponse{
		PartnerID: partnerID,
		KeyHash:   kh,
		RawKey:    rawKey,
	})
}

// RotateKey handles POST /v1/partners/{id}/keys/rotate.
func (h *RegistrationHandler) RotateKey(w http.ResponseWriter, r *http.Request) {
	partnerID := r.PathValue("id")
	if partnerID == "" {
		httpError(w, "missing partner id", http.StatusBadRequest)
		return
	}

	ctx := r.Context()
	p, err := h.akv.LoadPartner(ctx, partnerID)
	if err != nil {
		httpError(w, "partner not found", http.StatusNotFound)
		return
	}
	if p.Status != StatusApproved {
		httpError(w, "only approved partners can rotate keys", http.StatusConflict)
		return
	}

	oldKH := p.KeyHash

	rawKey, kh, err := GenerateKeyPair(p.Type)
	if err != nil {
		log.Printf("rotate key partner %s: gen: %v", partnerID, err)
		httpError(w, "key generation failed", http.StatusInternalServerError)
		return
	}

	p.KeyHash = kh
	if err := SavePartner(ctx, h.rdb, p); err != nil {
		log.Printf("rotate key partner %s: save: %v", partnerID, err)
		httpError(w, "failed to save partner", http.StatusInternalServerError)
		return
	}
	// Write new index entry before removing old — avoids gap where no key resolves.
	if err := IndexKeyHash(ctx, h.rdb, kh, partnerID); err != nil {
		log.Printf("rotate key partner %s: index: %v", partnerID, err)
		httpError(w, "failed to index new key", http.StatusInternalServerError)
		return
	}
	if err := RemoveKeyHashIndex(ctx, h.rdb, oldKH); err != nil {
		// Non-fatal: old index entry is stale but the record's KeyHash has changed,
		// so Validate() will reject it. Log and continue.
		log.Printf("rotate key partner %s: remove old index: %v", partnerID, err)
	}

	log.Printf("partner key rotated: id=%s old_kh=%s new_kh=%s", partnerID, oldKH, kh)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(KeyResponse{
		PartnerID: partnerID,
		KeyHash:   kh,
		RawKey:    rawKey,
	})
}

// Get handles GET /v1/partners/{id}.
func (h *RegistrationHandler) Get(w http.ResponseWriter, r *http.Request) {
	partnerID := r.PathValue("id")
	if partnerID == "" {
		httpError(w, "missing partner id", http.StatusBadRequest)
		return
	}
	ctx := r.Context()
	p, err := h.akv.LoadPartner(ctx, partnerID)
	if err != nil {
		httpError(w, "partner not found", http.StatusNotFound)
		return
	}
	// Scrub the key hash from the public view — only return safe fields.
	view := map[string]interface{}{
		"id":           p.ID,
		"name":         p.Name,
		"organization": p.Organization,
		"type":         string(p.Type),
		"fhir_version": p.FHIRVersion,
		"tier":         string(p.Tier),
		"status":       string(p.Status),
		"created_at":   p.CreatedAt,
		"approved_at":  p.ApprovedAt,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(view)
}

// syncApprovalToOdoo performs a best-effort Odoo sync in a goroutine.
// Logs failures; does NOT block or fail the HTTP response.
func syncApprovalToOdoo(p *Partner) {
	client, err := NewOdooClient()
	if err != nil {
		log.Printf("odoo sync: partner %s: client init: %v", p.ID, err)
		return
	}
	if err := client.SyncPartnerApproval(p); err != nil {
		log.Printf("odoo sync: partner %s: sync: %v", p.ID, err)
	}
}

func httpError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
