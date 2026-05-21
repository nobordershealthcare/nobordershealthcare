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

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		slog.Error("graceful shutdown failed", "err", err)
		os.Exit(1)
	}
	slog.Info("gatekeeper stopped cleanly")
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}
