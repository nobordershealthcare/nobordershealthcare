// main.go — NoBorders Healthcare API Gateway (port 8082).
//
// Separate service from gatekeeper — owns its own Ed25519 JWT signing key pair.
// All inbound TLS: minimum TLS 1.3, no fallback.
// Inter-service outbound calls use mTLS (CLIENT_TLS_CERT / CLIENT_TLS_KEY).
// Partner-facing: API key auth (X-API-Key header) + rate limiting + scope enforcement.
//
// Environment variables:
//
//	PORT              listen address, default :8082
//	REDIS_ADDR        Redis host:port, default localhost:6379
//	REDIS_PASSWORD    Redis auth, empty = no auth
//	TLS_CERT          server TLS certificate PEM path
//	TLS_KEY           server TLS private key PEM path
//	CLIENT_CA_CERT    CA PEM for mTLS admin endpoint client verification
//	CLIENT_TLS_CERT   mTLS client cert PEM (outbound calls to normalization)
//	CLIENT_TLS_KEY    mTLS client key PEM  (outbound calls to normalization)
//	NORMALIZATION_URL upstream normalization service base URL
//	ODOO_URL          Odoo instance URL
//	ODOO_DB           Odoo database name
//	ODOO_USER         Odoo service account username
//	ODOO_KEY          Odoo service account password / API key
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/nobordershealthcare/api-gateway/internal/billing"
	"github.com/nobordershealthcare/api-gateway/internal/fhir"
	"github.com/nobordershealthcare/api-gateway/internal/partner"
)

func main() {
	rdb := newRedisClient()
	defer rdb.Close()

	// Core partner services
	akv := partner.NewKeyValidator(rdb)
	rl := partner.NewRateLimiter(rdb)
	reg := partner.NewRegistrationHandler(rdb, akv)

	// FHIR services
	cc := fhir.NewConsentChecker(rdb)
	mtlsClient := buildMTLSHTTPClient()
	ph := fhir.NewPushHandler(rdb, akv, rl, cc, mtlsClient)
	plh := fhir.NewPullHandler(rdb, akv, rl, cc, mtlsClient)

	// Billing
	meter := billing.NewMeteringService(rdb)

	// Routes
	mux := http.NewServeMux()

	// Partner management — protected by mTLS (admin tier; no external exposure)
	mux.HandleFunc("POST /v1/partners/register", reg.Register)
	mux.HandleFunc("POST /v1/partners/{id}/approve", reg.Approve)
	mux.HandleFunc("POST /v1/partners/{id}/keys/rotate", reg.RotateKey)
	mux.HandleFunc("GET /v1/partners/{id}", reg.Get)

	// FHIR push (partner writes to patient record)
	mux.HandleFunc("POST /v1/fhir/{resourceType}", ph.Push)

	// FHIR pull (partner reads from patient record)
	mux.HandleFunc("GET /v1/fhir/{resourceType}/{id}", plh.Pull)
	mux.HandleFunc("GET /v1/fhir/{resourceType}", plh.Search)

	// Billing / usage
	mux.HandleFunc("GET /v1/billing/usage", meter.UsageHandler)
	mux.HandleFunc("GET /v1/billing/usage/{partnerID}", meter.PartnerUsageHandler)

	srv := &http.Server{
		Addr:         listenAddr(),
		Handler:      mux,
		TLSConfig:    buildInboundTLSConfig(),
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("api-gateway: listening on %s (TLS 1.3 min)", srv.Addr)
		if err := srv.ListenAndServeTLS(
			getenv("TLS_CERT", "certs/server.crt"),
			getenv("TLS_KEY", "certs/server.key"),
		); err != nil && err != http.ErrServerClosed {
			log.Fatalf("api-gateway: serve: %v", err)
		}
	}()

	<-stop
	log.Println("api-gateway: shutting down …")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("api-gateway: shutdown error: %v", err)
	}
	log.Println("api-gateway: stopped")
}

// newRedisClient creates a Redis client.
// Persistence is disabled at the server level (no AOF, no RDB) per security policy.
func newRedisClient() *redis.Client {
	return redis.NewClient(&redis.Options{
		Addr:         getenv("REDIS_ADDR", "localhost:6379"),
		Password:     os.Getenv("REDIS_PASSWORD"),
		DB:           0,
		DialTimeout:  5 * time.Second,
		ReadTimeout:  3 * time.Second,
		WriteTimeout: 3 * time.Second,
	})
}

// buildInboundTLSConfig returns a TLS 1.3-minimum config for inbound connections.
// If CLIENT_CA_CERT is set, mTLS is enforced on ALL connections (admin endpoints).
func buildInboundTLSConfig() *tls.Config {
	cfg := &tls.Config{
		MinVersion: tls.VersionTLS13,
	}
	caCertPath := os.Getenv("CLIENT_CA_CERT")
	if caCertPath == "" {
		return cfg
	}
	caPEM, err := os.ReadFile(caCertPath)
	if err != nil {
		log.Fatalf("api-gateway: read CLIENT_CA_CERT: %v", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		log.Fatalf("api-gateway: parse CLIENT_CA_CERT: no valid certs found")
	}
	cfg.ClientCAs = pool
	cfg.ClientAuth = tls.RequireAndVerifyClientCert
	return cfg
}

// buildMTLSHTTPClient returns an http.Client with the service's mTLS client certificate.
// Used for outbound calls to the normalization service.
func buildMTLSHTTPClient() *http.Client {
	certPath := getenv("CLIENT_TLS_CERT", "certs/client.crt")
	keyPath := getenv("CLIENT_TLS_KEY", "certs/client.key")

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		// Non-fatal at startup — log a warning; outbound FHIR forwarding will fail
		// gracefully if certs are missing (acceptable in local dev).
		log.Printf("api-gateway: WARNING — mTLS client cert not loaded: %v (FHIR forwarding disabled)", err)
		return &http.Client{
			Timeout: 30 * time.Second,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13},
			},
		}
	}
	tlsCfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
	}
	return &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: tlsCfg,
		},
	}
}

func listenAddr() string          { return getenv("PORT", ":8082") }
func getenv(k, fallback string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return fallback
}
