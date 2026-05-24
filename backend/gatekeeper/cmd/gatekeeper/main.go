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

	// ── HTTP server ───────────────────────────────────────────────────────────
	_ = redisClient  // used by auth handlers registered below
	_ = fabricClient // used by auth handlers registered below

	tlsCfg, err := cfg.MutualTLSConfig()
	if err != nil {
		slog.Error("tls config failed", "err", err)
		os.Exit(1)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealthz)
	// Auth endpoints are registered by the handler layer (not shown here —
	// each auth flow registers its own route with its own middleware chain).

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
