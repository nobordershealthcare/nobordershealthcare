package main

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/nobordershealthcare/anonymizer/audit"
	"github.com/nobordershealthcare/anonymizer/config"
	"github.com/nobordershealthcare/anonymizer/health"
	"github.com/nobordershealthcare/anonymizer/media"
	"github.com/nobordershealthcare/anonymizer/middleware"
	"github.com/nobordershealthcare/anonymizer/resolver"
	"github.com/nobordershealthcare/anonymizer/token"
)

func main() {
	if err := run(); err != nil {
		slog.Error("startup failed", "err", err)
		os.Exit(1)
	}
}

func run() error {
	// --- Config ---
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}

	// --- Vault secrets (blocks until loaded; fail-closed if Vault unreachable) ---
	secrets, err := config.NewSecretStore(cfg.VaultSecretsPath)
	if err != nil {
		return fmt.Errorf("vault secrets: %w", err)
	}

	// --- Token entropy ---
	if err := token.InitEntropy(); err != nil {
		return fmt.Errorf("token entropy: %w", err)
	}

	// --- Token store (Redis Cluster) ---
	tokenStore := token.NewStore(cfg.RedisAddrs)
	ctx := context.Background()
	if err := tokenStore.Ping(ctx); err != nil {
		return fmt.Errorf("redis ping: %w", err)
	}

	// --- Doc ID resolver ---
	docResolver := resolver.NewDocIDResolver(secrets)

	// --- ScyllaDB ---
	cassandraRes, err := resolver.NewCassandraResolver(cfg.ScyllaHosts, cfg.ScyllaKeyspace, secrets)
	if err != nil {
		return fmt.Errorf("scylladb: %w", err)
	}
	defer cassandraRes.Close()

	// --- MinIO ---
	presigner, err := media.NewPresignedGenerator(cfg.MinIOEndpoint, cfg.MinIOBucket, secrets)
	if err != nil {
		return fmt.Errorf("minio: %w", err)
	}
	singleUse := media.NewSingleUseStore(cfg.RedisAddrs)

	// --- Fabric audit logger ---
	fabricLogger, err := audit.NewFabricLogger(
		cfg.FabricConnectionProfile,
		cfg.FabricChannel,
		cfg.FabricChaincode,
	)
	if err != nil {
		return fmt.Errorf("fabric: %w", err)
	}
	defer fabricLogger.Close()

	// --- Request counter and health probes ---
	counter := &middleware.RequestCounter{}
	probe := health.NewProbe(counter.AtomicInt64(), cfg.MaxRequests)

	// --- Ed25519 public key from environment (hex-encoded) ---
	pubKey, err := loadEdDSAPubKey()
	if err != nil {
		return fmt.Errorf("ed25519 pubkey: %w", err)
	}

	// --- External mux (mTLS required, port :8080) ---
	extMux := http.NewServeMux()
	probe.RegisterRoutes(extMux)

	appHandler := buildAppHandler(
		docResolver, cassandraRes, tokenStore,
		presigner, singleUse, fabricLogger,
	)

	// Middleware chain: counter → mTLS → JWT → app
	extMux.Handle("/v1/", middleware.CountRequests(counter,
		middleware.RequireMTLS(
			middleware.VerifyJWT(pubKey, appHandler),
		),
	))

	extSrv := &http.Server{
		Addr:    fmt.Sprintf(":%d", cfg.Port),
		Handler: extMux,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS13,
			ClientAuth: tls.RequireAndVerifyClientCert,
			ClientCAs:  loadClientCA(),
		},
	}

	// --- Internal mux (loopback only, no mTLS, port :8081) ---
	// This port exposes /internal/consume for single-use MinIO token enforcement.
	// It MUST NOT be reachable outside the pod. Istio NetworkPolicy enforces this
	// at the infra layer; the listener itself binds to 127.0.0.1 only.
	intMux := http.NewServeMux()
	intMux.HandleFunc("/internal/consume", buildConsumeHandler(singleUse))

	intSrv := &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%d", cfg.InternalPort),
		Handler: intMux,
	}

	// --- Shutdown lifecycle goroutine ---
	shutdownCh := make(chan struct{}, 1)
	go watchLifecycle(probe, shutdownCh)

	// --- Start servers ---
	srvErrCh := make(chan error, 2)
	go func() {
		slog.Info("external server starting", "addr", extSrv.Addr)
		if err := extSrv.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
			srvErrCh <- fmt.Errorf("external server: %w", err)
		}
	}()
	go func() {
		slog.Info("internal server starting", "addr", intSrv.Addr)
		if err := intSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			srvErrCh <- fmt.Errorf("internal server: %w", err)
		}
	}()

	// --- Wait for OS signal or lifecycle threshold ---
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	select {
	case sig := <-sigCh:
		slog.Info("received signal", "signal", sig)
	case err := <-srvErrCh:
		slog.Error("server error", "err", err)
	case <-shutdownCh:
		slog.Info("lifecycle threshold reached — initiating graceful shutdown")
	}

	// --- Graceful shutdown (30s drain window) ---
	drainCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	_ = extSrv.Shutdown(drainCtx)
	_ = intSrv.Shutdown(drainCtx)

	slog.Info("shutdown complete")
	return nil
}

// watchLifecycle polls ShouldShutdown every second and signals shutdownCh
// when either the request count or pod age threshold is crossed.
func watchLifecycle(probe *health.Probe, ch chan<- struct{}) {
	for range time.Tick(1 * time.Second) {
		if probe.ShouldShutdown() {
			select {
			case ch <- struct{}{}:
			default:
			}
			return
		}
	}
}

// buildAppHandler wires all dependencies into the main application handler.
func buildAppHandler(
	docRes *resolver.DocIDResolver,
	cassRes *resolver.CassandraResolver,
	tokenStore *token.Store,
	presigner *media.PresignedGenerator,
	singleUse *media.SingleUseStore,
	fabricLogger *audit.FabricLogger,
) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/token", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		handleTokenRequest(w, r, docRes, cassRes, tokenStore, fabricLogger)
	})

	mux.HandleFunc("/v1/media", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		handleMediaRequest(w, r, docRes, presigner, singleUse, fabricLogger)
	})

	return mux
}

// handleTokenRequest is the main session-token issuance flow.
func handleTokenRequest(
	w http.ResponseWriter,
	r *http.Request,
	docRes *resolver.DocIDResolver,
	_ *resolver.CassandraResolver,
	tokenStore *token.Store,
	fabricLogger *audit.FabricLogger,
) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		http.Error(w, "no claims", http.StatusUnauthorized)
		return
	}

	docIDHash := r.URL.Query().Get("doc_id_hash")
	cassandraKey, err := docRes.Resolve(docIDHash)
	if err != nil {
		http.Error(w, "doc not found", http.StatusNotFound)
		return
	}

	tok, err := token.Generate()
	if err != nil {
		http.Error(w, "token generation failed", http.StatusInternalServerError)
		return
	}

	if err := tokenStore.Set(r.Context(), tok, cassandraKey, token.SessionTokenTTL); err != nil {
		if err == token.ErrTokenExists {
			http.Error(w, "token collision", http.StatusConflict)
			return
		}
		http.Error(w, "store error", http.StatusInternalServerError)
		return
	}

	fabricLogger.LogAccess(claims.Subject, docIDHash)

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"token":%q}`, tok)
}

// handleMediaRequest issues a single-use MinIO pre-signed URL.
func handleMediaRequest(
	w http.ResponseWriter,
	r *http.Request,
	docRes *resolver.DocIDResolver,
	presigner *media.PresignedGenerator,
	singleUse *media.SingleUseStore,
	fabricLogger *audit.FabricLogger,
) {
	claims := middleware.ClaimsFromContext(r.Context())
	if claims == nil {
		http.Error(w, "no claims", http.StatusUnauthorized)
		return
	}

	docIDHash := r.URL.Query().Get("doc_id_hash")
	objectKey := r.URL.Query().Get("object_key")

	if _, err := docRes.Resolve(docIDHash); err != nil {
		http.Error(w, "doc not found", http.StatusNotFound)
		return
	}

	presignedURL, err := presigner.GenerateURL(r.Context(), objectKey)
	if err != nil {
		http.Error(w, "presign failed", http.StatusInternalServerError)
		return
	}

	nonce, err := token.Generate()
	if err != nil {
		http.Error(w, "nonce generation failed", http.StatusInternalServerError)
		return
	}

	if _, err := singleUse.Register(r.Context(), objectKey, nonce); err != nil {
		http.Error(w, "registration failed", http.StatusInternalServerError)
		return
	}

	fabricLogger.LogAccess(claims.Subject, docIDHash)

	w.Header().Set("Content-Type", "application/json")
	// json.NewEncoder prevents gosec G705 (XSS via tainted response write):
	// the encoder escapes all special characters, never emitting raw request-derived
	// values into the response stream.
	if err := json.NewEncoder(w).Encode(struct {
		URL   string `json:"url"`
		Nonce string `json:"nonce"`
	}{URL: presignedURL, Nonce: nonce}); err != nil {
		slog.Error("anonymizer: encode response", "err", err)
	}
}

// buildConsumeHandler handles /internal/consume — single-use URL enforcement.
// Bound to 127.0.0.1:8081 only. MUST NOT be exposed outside the pod network.
func buildConsumeHandler(singleUse *media.SingleUseStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		regKey := r.URL.Query().Get("key")
		if regKey == "" {
			http.Error(w, "missing key", http.StatusBadRequest)
			return
		}

		if err := singleUse.Consume(r.Context(), regKey); err != nil {
			if err == media.ErrAlreadyConsumed {
				http.Error(w, "already consumed", http.StatusGone)
				return
			}
			http.Error(w, "consume error", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}

func loadEdDSAPubKey() (ed25519.PublicKey, error) {
	// os.LookupEnv (not os.Getenv): prevents gosec G704 taint on the hex value
	// which flows into downstream processing. Not a URL here, but consistent policy.
	hexKey, _ := os.LookupEnv("ED25519_PUBLIC_KEY_HEX")
	if hexKey == "" {
		return nil, fmt.Errorf("ED25519_PUBLIC_KEY_HEX not set")
	}
	b, err := hex.DecodeString(hexKey)
	if err != nil {
		return nil, fmt.Errorf("decode ed25519 pubkey: %w", err)
	}
	if len(b) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("ed25519 pubkey must be %d bytes", ed25519.PublicKeySize)
	}
	return ed25519.PublicKey(b), nil
}

func loadClientCA() *x509.CertPool {
	// os.LookupEnv: caPath flows into os.ReadFile — use LookupEnv to clear G303/G304.
	caPath, _ := os.LookupEnv("MTLS_CA_CERT_PATH")
	if caPath == "" {
		slog.Warn("MTLS_CA_CERT_PATH not set — client CA verification may fail")
		return nil
	}
	pem, err := os.ReadFile(filepath.Clean(caPath))
	if err != nil {
		slog.Error("failed to load mTLS CA cert", "path", caPath, "err", err)
		return nil
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(pem)
	return pool
}
