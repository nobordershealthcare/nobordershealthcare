// Command referral runs the NoBorders Healthcare referral service on :8088.
//
// Security invariants (enforced here):
//   - All user IDs arrive pre-hashed (SHA3-256) from gatekeeper — never raw IDs
//   - No PII is stored, logged, or forwarded
//   - Self-referral is rejected at the convert endpoint
//   - Velocity > 5 conversions/hour pauses the code and alerts
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"

	"github.com/nobordershealthcare/referral/internal/code"
	"github.com/nobordershealthcare/referral/internal/commission"
	"github.com/nobordershealthcare/referral/internal/models"
	"github.com/nobordershealthcare/referral/internal/odoo"
	"github.com/nobordershealthcare/referral/internal/payout"
	"github.com/nobordershealthcare/referral/internal/store"
	"github.com/nobordershealthcare/referral/internal/tracking"
)

// App holds all service dependencies.
type App struct {
	db      *store.DB
	rdb     *redis.Client
	tracker *tracking.Tracker
	payer   *payout.Client
	sched   *payout.Scheduler
	odooC   *odoo.Client
}

func main() {
	ctx := context.Background()

	// ── ScyllaDB ──────────────────────────────────────────────────────────
	hosts := strings.Split(envOr("SCYLLA_HOSTS", "scylladb:9042"), ",")
	db, err := store.New(hosts, envOr("SCYLLA_KEYSPACE", "referral"))
	if err != nil {
		log.Fatalf("scylla init: %v", err)
	}
	defer db.Close()

	// ── Redis ─────────────────────────────────────────────────────────────
	rdb := redis.NewClient(&redis.Options{
		Addr:     envOr("REDIS_ADDR", "redis:6379"),
		Password: os.Getenv("REDIS_PASSWORD"),
	})
	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("redis ping: %v", err)
	}

	// ── Stripe Connect ────────────────────────────────────────────────────
	stripeClient := payout.New()

	// ── Odoo ──────────────────────────────────────────────────────────────
	odooClient := odoo.New()

	// ── Scheduler ─────────────────────────────────────────────────────────
	sched := payout.NewScheduler(db, stripeClient, odooClient)
	sched.Start(ctx)

	app := &App{
		db:      db,
		rdb:     rdb,
		tracker: tracking.New(rdb),
		payer:   stripeClient,
		sched:   sched,
		odooC:   odooClient,
	}

	// ── Router ────────────────────────────────────────────────────────────
	r := chi.NewRouter()
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(30 * time.Second))

	r.Post("/referral/code/create", app.handleCreateCode)
	r.Get("/referral/code/validate/{code}", app.handleValidateCode)
	r.Post("/referral/convert", app.handleConvert)
	r.Post("/referral/accrue", app.handleAccrue)
	r.Get("/referral/stats/{referrer_hash}", app.handleStats)
	r.Post("/referral/deactivate/{conversion_id}", app.handleDeactivate)
	r.Post("/referral/payout/trigger", app.adminOnly(app.handlePayoutTrigger))
	r.Post("/referral/stripe/onboard", app.handleStripeOnboard)
	r.Get("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	addr := envOr("LISTEN_ADDR", ":8088")
	log.Printf("[referral] listening on %s", addr)
	// Explicit timeouts prevent Slowloris / resource-exhaustion attacks (gosec G114).
	srv := &http.Server{
		Addr:         addr,
		Handler:      r,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("server: %v", err)
	}
}

// ── Middleware ───────────────────────────────────────────────────────────────

func (a *App) adminOnly(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Admin") != "true" {
			writeErr(w, http.StatusForbidden, "admin only")
			return
		}
		next(w, r)
	}
}

// ── Handlers ─────────────────────────────────────────────────────────────────

// POST /referral/code/create
// Body: {"referral_type":"individual|partner|affiliate|provider","stripe_account_id":"acct_..."}
// Header: X-Referrer-Hash: <sha3-256 hex set by gatekeeper>
func (a *App) handleCreateCode(w http.ResponseWriter, r *http.Request) {
	referrerHash := r.Header.Get("X-Referrer-Hash")
	if len(referrerHash) != 64 {
		writeErr(w, http.StatusUnauthorized, "missing or invalid X-Referrer-Hash")
		return
	}

	var req struct {
		ReferralType    string `json:"referral_type"`
		StripeAccountID string `json:"stripe_account_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}

	rc, err := code.Generate(referrerHash, models.ReferralType(req.ReferralType), req.StripeAccountID)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}

	if err := a.db.CreateCode(r.Context(), rc); err != nil {
		log.Printf("[referral] CreateCode error referrerHash=%.8s: %v", referrerHash, err)
		writeErr(w, http.StatusInternalServerError, "store error")
		return
	}

	appBase := envOr("APP_BASE_URL", "https://app.noborders.healthcare")
	shortLink := fmt.Sprintf("%s/r/%s", appBase, rc.Code)
	writeJSON(w, http.StatusCreated, map[string]string{
		"code":       rc.Code,
		"short_link": shortLink,
	})
}

// GET /referral/code/validate/{code}
func (a *App) handleValidateCode(w http.ResponseWriter, r *http.Request) {
	codeParam := chi.URLParam(r, "code")
	rc, err := a.db.GetCodeByCode(r.Context(), codeParam)
	if err != nil {
		writeErr(w, http.StatusNotFound, "code not found")
		return
	}

	if err := code.Validate(rc); err != nil {
		writeErr(w, http.StatusGone, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"valid":         true,
		"referral_type": string(rc.ReferralType),
		"referrer_hash": rc.ReferrerHash,
	})
}

// POST /referral/convert
// Called by subscription service on new subscription.
// Body: {"code_hash":"...","referred_hash":"...","subscription_id":"...","plan":"..."}
func (a *App) handleConvert(w http.ResponseWriter, r *http.Request) {
	var req struct {
		CodeHash       string `json:"code_hash"`
		ReferredHash   string `json:"referred_hash"`
		SubscriptionID string `json:"subscription_id"`
		Plan           string `json:"plan"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}

	if len(req.ReferredHash) != 64 || len(req.CodeHash) != 64 {
		writeErr(w, http.StatusBadRequest, "referred_hash and code_hash must be 64-char SHA3-256 hex")
		return
	}

	rc, err := a.db.GetCodeByHash(r.Context(), req.CodeHash)
	if err != nil {
		writeErr(w, http.StatusNotFound, "code not found")
		return
	}

	// Validate code is still usable
	if err := code.Validate(rc); err != nil {
		writeErr(w, http.StatusGone, err.Error())
		return
	}

	// selfReferral check — same hash means same user; reject immediately
	if err := a.tracker.CheckSelfReferral(rc.ReferrerHash, req.ReferredHash); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}

	// Velocity fraud check
	overLimit, velErr := a.tracker.CheckVelocity(r.Context(), req.CodeHash)
	if velErr != nil {
		log.Printf("[referral] velocity check error codeHash=%.8s: %v", req.CodeHash, velErr)
	}
	if overLimit {
		log.Printf("[referral] velocity limit exceeded — pausing code codeHash=%.8s", req.CodeHash)
		_ = a.db.PauseCode(r.Context(), req.CodeHash)
		writeErr(w, http.StatusTooManyRequests, "code temporarily suspended for review")
		return
	}

	// Attribution: first touch wins
	if touchErr := a.tracker.RecordFirstTouch(r.Context(), req.ReferredHash, req.CodeHash); touchErr != nil {
		log.Printf("[referral] first touch record error: %v", touchErr)
	}
	_ = a.db.AppendAttributionCode(r.Context(), req.ReferredHash, req.CodeHash)

	// Determine commission type
	commType := models.CommissionTypeRevShare
	initRate := 0.0
	switch rc.ReferralType {
	case models.TypePartner:
		initRate = 0.15
	case models.TypeAffiliate:
		initRate = 0.20
	default:
		commType = models.CommissionTypeCredit
	}

	conv := &models.ReferralConversion{
		ID:              uuid.New().String(),
		CodeHash:        req.CodeHash,
		ReferrerHash:    rc.ReferrerHash,
		ReferredHash:    req.ReferredHash,
		ReferralType:    rc.ReferralType,
		StripeAccountID: rc.StripeAccountID,
		ConvertedAt:     time.Now().UTC(),
		SubscriptionID:  req.SubscriptionID,
		PlanTier:        req.Plan,
		CommissionRate:  initRate,
		CommissionType:  commType,
		Status:          models.StatusApproved,
	}

	if err := a.db.CreateConversion(r.Context(), conv); err != nil {
		log.Printf("[referral] CreateConversion error: %v", err)
		writeErr(w, http.StatusInternalServerError, "store error")
		return
	}

	// Increment code usage
	_ = a.db.IncrementUsage(r.Context(), req.CodeHash)

	// Sync to Odoo
	if err := a.odooC.SyncConversion(r.Context(), conv); err != nil {
		log.Printf("[referral] OdooSync conversion id=%s: %v", conv.ID, err)
	}

	// For provider type: grant API credits (via api-gateway sidecar)
	if rc.ReferralType == models.TypeProvider {
		grantAPICredits(conv.ReferrerHash, models.APICreditsPerActivation)
	}

	writeJSON(w, http.StatusCreated, map[string]string{"conversion_id": conv.ID})
}

// POST /referral/accrue
// Called by subscription service on monthly payment success.
// Body: {"conversion_id":"...","revenue_eur":49.99,"period":"2026-05"}
func (a *App) handleAccrue(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ConversionID string  `json:"conversion_id"`
		RevenueEUR   float64 `json:"revenue_eur"`
		Period       string  `json:"period"` // "YYYY-MM"
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}

	conv, err := a.db.GetConversion(r.Context(), req.ConversionID)
	if err != nil {
		writeErr(w, http.StatusNotFound, "conversion not found")
		return
	}

	accrual, err := commission.Accrue(conv, req.RevenueEUR, req.Period, time.Now().UTC())
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if accrual == nil {
		// credit type — no cash accrual
		writeJSON(w, http.StatusOK, map[string]string{"status": "credit_type_no_accrual"})
		return
	}

	if err := a.db.CreateAccrual(r.Context(), accrual); err != nil {
		log.Printf("[referral] CreateAccrual error: %v", err)
		writeErr(w, http.StatusInternalServerError, "store error")
		return
	}

	if err := a.odooC.SyncAccrual(r.Context(), accrual); err != nil {
		log.Printf("[referral] OdooSync accrual id=%s: %v", accrual.ID, err)
	}

	writeJSON(w, http.StatusCreated, map[string]string{"accrual_id": accrual.ID})
}

// GET /referral/stats/{referrer_hash}
func (a *App) handleStats(w http.ResponseWriter, r *http.Request) {
	referrerHash := chi.URLParam(r, "referrer_hash")
	if len(referrerHash) != 64 {
		writeErr(w, http.StatusBadRequest, "referrer_hash must be 64-char SHA3-256 hex")
		return
	}

	convs, err := a.db.ListConversionsByReferrer(r.Context(), referrerHash)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "store error")
		return
	}

	pending, _ := a.db.SumPendingCommission(r.Context(), referrerHash)
	paid, _ := a.db.SumPaidCommission(r.Context(), referrerHash)
	active, _ := a.db.CountActiveByReferrer(r.Context(), referrerHash)

	// API credits: count provider conversions × APICreditsPerActivation
	credits := 0
	for _, c := range convs {
		if c.ReferralType == models.TypeProvider && c.Status == models.StatusApproved {
			credits += models.APICreditsPerActivation
		}
	}

	writeJSON(w, http.StatusOK, models.ReferralStats{
		TotalConversions:  len(convs),
		PendingCommission: pending,
		PaidCommission:    paid,
		ActiveReferred:    active,
		CreditsEarned:     credits,
	})
}

// POST /referral/deactivate/{conversion_id}
func (a *App) handleDeactivate(w http.ResponseWriter, r *http.Request) {
	convID := chi.URLParam(r, "conversion_id")
	if err := a.db.DeactivateConversion(r.Context(), convID); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /referral/payout/trigger  [admin only]
func (a *App) handlePayoutTrigger(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Period string `json:"period"` // "YYYY-MM", defaults to previous month
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.Period == "" {
		prev := time.Now().UTC().AddDate(0, -1, 0)
		req.Period = fmt.Sprintf("%04d-%02d", prev.Year(), int(prev.Month()))
	}

	// context.WithoutCancel: payout runs to completion even if the HTTP response
	// is already sent; 10-minute timeout caps the goroutine lifetime (G118).
	payCtx, payCancel := context.WithTimeout(context.WithoutCancel(r.Context()), 10*time.Minute)
	go func() {
		defer payCancel()
		if err := a.sched.RunMonthlyPayout(payCtx, req.Period); err != nil {
			log.Printf("[referral] manual payout error period=%q: %v", req.Period, err)
		}
	}()

	writeJSON(w, http.StatusAccepted, map[string]string{"period": req.Period, "status": "triggered"})
}

// POST /referral/stripe/onboard
// Creates a Stripe Express account + returns onboarding URL.
// No PII accepted — partner fills details on Stripe's hosted flow.
func (a *App) handleStripeOnboard(w http.ResponseWriter, r *http.Request) {
	refreshURL := envOr("STRIPE_REFRESH_URL", "https://app.noborders.healthcare/partner/onboard/refresh")
	returnURL := envOr("STRIPE_RETURN_URL", "https://app.noborders.healthcare/partner/onboard/complete")

	accountID, onboardURL, err := a.payer.OnboardPartner(refreshURL, returnURL)
	if err != nil {
		log.Printf("[referral] Stripe onboard error: %v", err)
		writeErr(w, http.StatusBadGateway, "stripe error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"stripe_account_id": accountID,
		"onboard_url":       onboardURL,
	})
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// grantAPICredits calls the api-gateway sidecar to credit API calls.
// Fire-and-forget; errors are logged but do not fail the conversion.
func grantAPICredits(referrerHash string, credits int) {
	gatewayURL := envOr("API_GATEWAY_URL", "http://api-gateway.noborders.svc.cluster.local:8080")
	url := fmt.Sprintf("%s/internal/credits/grant", gatewayURL)
	body, _ := json.Marshal(map[string]any{
		"referrer_hash": referrerHash,
		"credits":       credits,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(string(body)))
	if req != nil {
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			log.Printf("[referral] grantAPICredits referrerHash=%.8s: %v", referrerHash, err)
			return
		}
		resp.Body.Close()
	}
}
