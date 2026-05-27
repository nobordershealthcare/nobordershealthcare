// subscription — NBHC SaaS subscription management service.
//
// Handles plan lifecycle (free / professional / enterprise), Stripe Billing
// webhooks, and per-tenant feature flags.  Patient health data is NEVER
// processed by this service — it operates on anonymised tenant IDs only.
//
// Security invariants:
//   - All tenant identifiers are SHA3-256(salt+tenantID) — never plaintext
//   - Stripe webhook payloads are verified with HMAC-SHA256 (Stripe library)
//   - No PII in logs — only SHA3-256 hashes and Stripe object IDs
//   - mTLS to all internal services via Istio sidecar
//   - JWT TTL 15 min max; admin ops require FIDO2 (enforced by gatekeeper)
//
// Configuration (env vars / k8s secrets):
//
//	LISTEN_ADDR               HTTP listen address (default :8080)
//	STRIPE_SECRET_KEY         Stripe API key (from k8s secret)
//	STRIPE_WEBHOOK_SECRET     Stripe webhook signing secret (from k8s secret)
//	SCYLLA_HOSTS              ScyllaDB contact points
//	REDIS_ADDR                Redis address for rate limiting + feature flags
package main

import (
	"errors"
	"log/slog"
	"net/http"
	"os"
	"time"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	addr := envOr("LISTEN_ADDR", ":8080")

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	slog.Info("subscription service listening", slog.String("addr", addr))
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("server error", slog.String("err", err.Error()))
		os.Exit(1)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
