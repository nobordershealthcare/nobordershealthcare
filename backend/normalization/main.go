// Package main is the entrypoint for the normalization service.
//
// Start order:
//  1. Load config from env vars (fail loud on missing vars)
//  2. Authenticate to Vault → fetch Ed25519 public key + KeyFetcher
//  3. Connect to ScyllaDB CDR
//  4. Build Kafka producer, consumer, review producer
//  5. Build Fabric audit client
//  6. Start health check server (port 8081)
//  7. Start FHIR R4 API server (FHIR_LISTEN_ADDR, default :8080)
//  8. Start normalization pipeline loop (goroutine)
//  9. Block until SIGTERM/SIGINT → graceful shutdown
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/hyperledger/fabric-gateway/pkg/identity"

	"github.com/nobordershealthcare/normalization/audit"
	"github.com/nobordershealthcare/normalization/cdr"
	nconfig "github.com/nobordershealthcare/normalization/config"
	"github.com/nobordershealthcare/normalization/fhir"
	"github.com/nobordershealthcare/normalization/health"
	"github.com/nobordershealthcare/normalization/kafka"
	"github.com/nobordershealthcare/normalization/normalizer"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(log)

	if err := run(log); err != nil {
		log.Error("fatal startup error", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	// ── 1. Config ─────────────────────────────────────────────────────────────
	cfg, err := nconfig.Load()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}
	log.Info("config loaded",
		"kafka_brokers", len(cfg.KafkaBrokers),
		"scylla_hosts", len(cfg.ScyllaHosts),
		"fhir_addr", cfg.ListenAddr,
	)

	// ── 2. Vault ──────────────────────────────────────────────────────────────
	vaultClient, err := nconfig.NewVaultClient(cfg.VaultAddr, cfg.VaultRole)
	if err != nil {
		return fmt.Errorf("vault: %w", err)
	}
	log.Info("vault authenticated")

	edPubKey, err := vaultClient.FetchEdDSAPublicKey()
	if err != nil {
		return fmt.Errorf("vault: fetch EdDSA public key: %w", err)
	}
	log.Info("EdDSA public key loaded")

	// KeyFetcher wraps Vault for per-patient AES key retrieval.
	keyFetcher := cdr.KeyFetcher(vaultClient.FetchAESKey)

	// ── 3. ScyllaDB ───────────────────────────────────────────────────────────
	scyllaSession, err := cdr.NewSession(cfg.ScyllaHosts, cfg.ScyllaCert, cfg.ScyllaKey, cfg.ScyllaCA)
	if err != nil {
		return fmt.Errorf("scylladb: %w", err)
	}
	defer scyllaSession.Close()
	log.Info("ScyllaDB connected")

	cdrWriter := cdr.NewWriter(scyllaSession, keyFetcher)
	cdrReader := cdr.NewReader(scyllaSession, keyFetcher)

	// ── 4. Kafka ──────────────────────────────────────────────────────────────
	producer := kafka.NewProducer(cfg.KafkaBrokers)
	defer func() { _ = producer.Close() }()

	consumer := kafka.NewConsumer(cfg.KafkaBrokers)
	defer func() { _ = consumer.Close() }()

	reviewProducer := kafka.NewReviewProducer(cfg.KafkaBrokers)
	defer func() { _ = reviewProducer.Close() }()

	log.Info("Kafka clients ready")

	// ── 5. Fabric audit ───────────────────────────────────────────────────────
	fabricContract, err := buildFabricContract(cfg)
	if err != nil {
		// Fabric audit failure is non-fatal at startup — log and continue.
		// RecordNormalization already handles individual failures as WARN.
		log.Warn("fabric client init failed — audit disabled", "err", err)
	}
	var auditor *audit.FabricAuditor
	if fabricContract != nil {
		auditor = audit.NewFabricAuditor(fabricContract, log)
		log.Info("Fabric audit client ready")
	}
	_ = auditor // auditor is nil if Fabric is unavailable; callers must nil-check

	// ── 6. Health server (port 8081) ──────────────────────────────────────────
	healthSrv := &http.Server{
		Addr:         ":8081",
		Handler:      health.Handler(scyllaSession),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
	}
	go func() {
		if err := healthSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("health server error", "err", err)
		}
	}()
	log.Info("health server started", "addr", ":8081")

	// ── 7. FHIR R4 API server ─────────────────────────────────────────────────
	fhirRouter := fhir.NewRouter(edPubKey, cdrReader)
	fhirSrv := &http.Server{
		Addr:         cfg.ListenAddr,
		Handler:      fhirRouter,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}
	go func() {
		log.Info("FHIR server started", "addr", cfg.ListenAddr)
		if err := fhirSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("FHIR server error", "err", err)
		}
	}()

	// ── 8. Normalization pipeline ─────────────────────────────────────────────
	pipeline := normalizer.NewPipeline(consumer, reviewProducer, cdrWriter, keyFetcher, log)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		if err := pipeline.Run(ctx); err != nil && err != context.Canceled {
			log.Error("pipeline error", "err", err)
		}
	}()
	log.Info("normalization pipeline started")

	// Suppress unused variable warning for producer (used by ingest path, future work).
	_ = producer

	// ── 9. Graceful shutdown ──────────────────────────────────────────────────
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)
	sig := <-quit
	log.Info("shutdown signal received", "signal", sig.String())

	// Cancel pipeline first.
	cancel()

	// Shutdown HTTP servers with a deadline.
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()

	if err := fhirSrv.Shutdown(shutdownCtx); err != nil {
		log.Error("FHIR server shutdown error", "err", err)
	}
	if err := healthSrv.Shutdown(shutdownCtx); err != nil {
		log.Error("health server shutdown error", "err", err)
	}

	log.Info("normalization service stopped cleanly")
	return nil
}

// buildFabricContract establishes a Hyperledger Fabric Gateway connection and
// returns the audit chaincode contract handle. Returns nil on error (non-fatal).
func buildFabricContract(cfg *nconfig.Config) (*client.Contract, error) {
	// Load client certificate and key.
	certPEM, err := os.ReadFile(cfg.FabricCertPath)
	if err != nil {
		return nil, fmt.Errorf("read fabric cert: %w", err)
	}
	keyPEM, err := os.ReadFile(cfg.FabricKeyPath)
	if err != nil {
		return nil, fmt.Errorf("read fabric key: %w", err)
	}
	tlsCertPEM, err := os.ReadFile(cfg.FabricTLSCertPath)
	if err != nil {
		return nil, fmt.Errorf("read fabric TLS cert: %w", err)
	}

	// Build mTLS credentials for gRPC.
	certPool := x509.NewCertPool()
	certPool.AppendCertsFromPEM(tlsCertPEM)
	clientCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("fabric x509 keypair: %w", err)
	}
	tlsCfg := &tls.Config{
		RootCAs:      certPool,
		Certificates: []tls.Certificate{clientCert},
		MinVersion:   tls.VersionTLS13,
	}

	grpcConn, err := grpc.NewClient(cfg.FabricEndpoint,
		grpc.WithTransportCredentials(credentials.NewTLS(tlsCfg)),
	)
	if err != nil {
		return nil, fmt.Errorf("fabric gRPC connect: %w", err)
	}

	// Parse the PEM certificate, then build the Fabric Gateway identity.
	parsedCert, err := identity.CertificateFromPEM(certPEM)
	if err != nil {
		return nil, fmt.Errorf("fabric parse cert: %w", err)
	}
	id, err := identity.NewX509Identity(cfg.FabricMSPID, parsedCert)
	if err != nil {
		return nil, fmt.Errorf("fabric identity: %w", err)
	}

	privateKey, err := identity.PrivateKeyFromPEM(keyPEM)
	if err != nil {
		return nil, fmt.Errorf("fabric private key: %w", err)
	}
	sign, err := identity.NewPrivateKeySign(privateKey)
	if err != nil {
		return nil, fmt.Errorf("fabric signer: %w", err)
	}

	gateway, err := client.Connect(id,
		client.WithSign(sign),
		client.WithClientConnection(grpcConn),
		client.WithEvaluateTimeout(5*time.Second),
		client.WithEndorseTimeout(15*time.Second),
		client.WithSubmitTimeout(5*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("fabric gateway connect: %w", err)
	}

	network := gateway.GetNetwork(cfg.FabricChannel)
	return network.GetContract(cfg.FabricChaincode), nil
}
