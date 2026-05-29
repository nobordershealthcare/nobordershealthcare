package main

import (
	"context"
	"crypto/tls"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nobordershealthcare/gatekeeper/internal/config"
	"github.com/nobordershealthcare/gatekeeper/internal/diia"
	"github.com/nobordershealthcare/gatekeeper/internal/fabric"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	cfg, err := config.Load()
	if err != nil {
		slog.Error("config load failed", "err", err)
		os.Exit(1)
	}

	// ── Redis (shared: jti replay + consent revoke keys) ─────────────────────
	redisClient, err := cfg.BuildRedisClient()
	if err != nil {
		slog.Error("redis client build failed", "err", err)
		os.Exit(1)
	}

	// ── Fabric client (channel 3 / access control) ────────────────────────────
	fabricClient, err := fabric.New(fabric.Config{
		Endpoint:    cfg.FabricEndpoint,
		MSPID:       cfg.FabricMSPID,
		CertPEM:     mustReadFile(cfg.FabricCertPath),
		KeyPEM:      mustReadFile(cfg.FabricKeyPath),
		TLSCACert:   mustReadFile(cfg.FabricTLSCAPath),
		ChannelName: cfg.FabricChannelName,
		Chaincode:   cfg.FabricChaincode,
		Timeout:     cfg.FabricTimeout,
	})
	if err != nil {
		slog.Error("fabric client init failed", "err", err)
		os.Exit(1)
	}
	defer fabricClient.Close()

	// ── Consent watcher (channel 2 / consent-audit) ───────────────────────────
	// Reuses the same gateway connection as the access-control client.
	// Subscribes from block 0 on every startup to rehydrate Redis revoke keys.
	consentNetwork := fabricClient.GetNetwork(cfg.FabricConsentChannel)
	watcher := fabric.NewConsentWatcher(consentNetwork, cfg.FabricConsentChaincode, redisClient)

	watcherCtx, cancelWatcher := context.WithCancel(context.Background())
	defer cancelWatcher()

	go func() {
		if err := watcher.Run(watcherCtx); err != nil && watcherCtx.Err() == nil {
			slog.Error("consent watcher exited unexpectedly", "err", err)
			os.Exit(1)
		}
	}()

	// ── Diia client + bootstrap ──────────────────────────────────────────────
	// NewFromEnv requires DIIA_ACQUIRER_TOKEN + DIIA_AUTH_ACQUIRER_TOKEN.
	// Bootstrap lists/creates branches and offers; reuses existing resources.
	// After first run: set DIIA_BRANCH_ID / DIIA_OFFER_ID_SIGNING / DIIA_OFFER_ID_AUTH
	// in k8s secrets to skip API calls on restart.
	diiaStore := diia.NewStore(redisClient)

	diiaClient, err := diia.NewFromEnv(nil)
	if err != nil {
		// Non-fatal: gatekeeper runs without Diia if tokens are absent (dev mode).
		slog.Warn("diia client init failed — Diia endpoints disabled", "err", err)
	}

	var diiaIDs *diia.IDCache
	if diiaClient != nil {
		bootstrapCtx, bootstrapCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer bootstrapCancel()
		diiaIDs, err = diia.Bootstrap(bootstrapCtx, diiaClient)
		if err != nil {
			slog.Error("diia bootstrap failed", "err", err)
			// Continue — existing endpoints still work without bootstrap.
		}
	}

	// ── HTTP server ───────────────────────────────────────────────────────────
	_ = fabricClient // used by future auth handlers

	tlsCfg, err := cfg.MutualTLSConfig()
	if err != nil {
		slog.Error("tls config failed", "err", err)
		os.Exit(1)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealthz)

	// ── Diia v1: CAdES-BES signing callback ──────────────────────────────────
	// api-gateway: POST /diia/sign/callback → POST /v1/diia/sign/callback
	mux.HandleFunc("POST /v1/diia/sign/callback", diia.HandleSignCallback(diiaStore))

	// ── Diia v1: identity auth (RNOKPP + name, server-side extraction) ────────
	if diiaClient != nil {
		mux.HandleFunc("POST /v1/diia/auth/request",           diia.HandleAuthRequest(diiaClient, diiaStore))
		mux.HandleFunc("GET /v1/diia/auth/status/{requestId}", diia.HandleAuthStatus(diiaStore))
		mux.HandleFunc("POST /v1/diia/auth/callback",          diia.HandleAuthCallback(diiaStore))
	}

	// ── Diia v2: dynamic offer-request (encodeData → iOS) ────────────────────
	// Scenario 1: hashedFilesSigning — POST /v1/diia/sign → deeplink
	// Scenario 2: auth               — POST /v1/diia/auth → deeplink
	// Callback  : POST /v1/diia/callback (multipart/mixed with encodeData)
	// Status    : GET  /v1/diia/status/{requestId} (one-time, deletes on read)
	if diiaIDs != nil {
		mux.HandleFunc("POST /v1/diia/sign",              diia.HandleDiiaSign(diiaClient, diiaIDs, diiaStore))
		mux.HandleFunc("POST /v1/diia/auth",              diia.HandleDiiaAuth(diiaClient, diiaIDs, diiaStore))
		mux.HandleFunc("POST /v1/diia/callback",          diia.HandleDiiaCallback(diiaStore))
		mux.HandleFunc("GET /v1/diia/status/{requestId}", diia.HandleDiiaStatus(diiaStore))
	}

	srv := &http.Server{
		Addr:    cfg.ListenAddr,
		Handler: mux,
		TLSConfig: &tls.Config{
			// MutualTLSConfig already sets MinVersion and ClientAuth.
			// We copy the fields rather than override the whole struct.
			Certificates: tlsCfg.Certificates,
			ClientCAs:    tlsCfg.ClientCAs,
			ClientAuth:   tlsCfg.ClientAuth,
			MinVersion:   tls.VersionTLS13, // TLS 1.3 minimum — no fallback
		},
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		slog.Info("gatekeeper starting", "addr", cfg.ListenAddr)
		// ListenAndServeTLS with empty cert/key — already set in TLSConfig.
		if err := srv.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "err", err)
			os.Exit(1)
		}
	}()

	<-stop
	slog.Info("shutdown signal received")

	// Cancel the consent watcher first so the Fabric event stream closes cleanly
	// before we drain in-flight HTTP requests.
	cancelWatcher()

	shutCtx, shutCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer shutCancel()

	if err := srv.Shutdown(shutCtx); err != nil {
		slog.Error("graceful shutdown failed", "err", err)
		os.Exit(1)
	}
	slog.Info("gatekeeper stopped cleanly")
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}

// mustReadFile reads a file and exits on failure. Used for loading PEM blobs
// at startup — if a cert path is wrong the pod should crash rather than run
// with an empty identity.
func mustReadFile(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		slog.Error("failed to read required file", "path", path, "err", err)
		os.Exit(1)
	}
	return data
}
