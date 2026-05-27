// main.go — NBHC Token Bridge (port 8085)
//
// Bridges Polygon NBHC token events to the internal Hyperledger Fabric
// channel5-token ledger.  Responsibilities:
//   - Subscribe to Polygon Transfer events → sync new holders to Fabric
//   - Run quarterly EURC distribution cycles (triggered via POST /v1/distribution/run)
//   - Expose /v1/distribution/history/{holderHash} for MiCA Art.71 statements
//
// Environment variables:
//
//	PORT                    listen address, default :8085
//	POLYGON_RPC_URL         Polygon WebSocket RPC (wss://…)
//	NBHC_CONTRACT_ADDR       NBHC ERC-20 contract address (0x…)
//	NBHC_GENESIS_BLOCK       Polygon block number of NBHC contract deploy
//	HOLDER_SALT             hex-encoded salt for SHA3-256(salt+address) — must come from Vault
//	FABRIC_PEER_ENDPOINT    Fabric peer gRPC address (host:port)
//	FABRIC_PEER_TLS_CERT    path to peer TLS certificate PEM
//	FABRIC_MSP_ID           MSP identifier, e.g. "Org1MSP"
//	FABRIC_CERT_PEM         path to service identity certificate
//	FABRIC_KEY_PEM          path to service identity private key
//	STRIPE_API_KEY          Stripe secret key (loaded from k8s secret)
//	EURC_CONTRACT_ADDR      Polygon EURC ERC-20 address (for on-chain rail)
//	TLS_CERT                inbound TLS certificate path
//	TLS_KEY                 inbound TLS private key path
//	CLIENT_CA_CERT          CA PEM for mTLS admin endpoint verification
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/nobordershealthcare/token-bridge/internal/distribution"
	"github.com/nobordershealthcare/token-bridge/internal/fabric"
	"github.com/nobordershealthcare/token-bridge/internal/payment"
	"github.com/nobordershealthcare/token-bridge/internal/polygon"
)

func main() {
	holderSalt, err := hex.DecodeString(mustEnv("HOLDER_SALT"))
	if err != nil {
		log.Fatalf("token-bridge: HOLDER_SALT must be a hex string: %v", err)
	}

	// Polygon listener
	listener, err := polygon.NewListener(
		mustEnv("POLYGON_RPC_URL"),
		common.HexToAddress(mustEnv("NBHC_CONTRACT_ADDR")),
		holderSalt,
	)
	if err != nil {
		log.Fatalf("token-bridge: polygon listener init: %v", err)
	}

	// Fabric client
	fabClient, err := fabric.New(fabric.Config{
		PeerEndpoint:       mustEnv("FABRIC_PEER_ENDPOINT"),
		GatewayPeerTLSCert: mustEnv("FABRIC_PEER_TLS_CERT"),
		MSPID:              mustEnv("FABRIC_MSP_ID"),
		CertPEM:            mustEnv("FABRIC_CERT_PEM"),
		KeyPEM:             mustEnv("FABRIC_KEY_PEM"),
	})
	if err != nil {
		log.Fatalf("token-bridge: fabric client init: %v", err)
	}
	defer fabClient.Close()

	// Payment dispatcher
	payDispatcher := payment.New()

	// Distribution calculator
	genesis, _ := strconv.ParseUint(getenv("NBHC_GENESIS_BLOCK", "0"), 10, 64)
	calc := distribution.New(listener, fabClient, payDispatcher, genesis)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Background: Polygon event listener
	go func() {
		if err := listener.Run(ctx); err != nil && ctx.Err() == nil {
			log.Printf("token-bridge: polygon listener exited: %v", err)
		}
	}()

	// Background: forward new holder events to calculator
	go func() {
		for evt := range listener.NewHolder {
			calc.SyncNewHolder(ctx, evt)
		}
	}()

	// HTTP API (mTLS for admin endpoints)
	mux := http.NewServeMux()

	// Trigger a quarterly distribution run (admin — mTLS protected)
	// POST /v1/distribution/run  Body: {"period":"2026-Q2"}
	mux.HandleFunc("POST /v1/distribution/run", makeRunHandler(calc))

	// MiCA Art.71 holder statement
	// GET /v1/distribution/history/{holderHash}
	mux.HandleFunc("GET /v1/distribution/history/{holderHash}", makeHistoryHandler(fabClient))

	// Revenue allocation (admin — mTLS protected)
	// POST /v1/distribution/allocate  Body: {"period":"2026-Q2","totalRevenue":"1000000000"}
	mux.HandleFunc("POST /v1/distribution/allocate", makeAllocateHandler(fabClient))

	// Consent management
	// POST /v1/holders/{holderHash}/consent
	mux.HandleFunc("POST /v1/holders/{holderHash}/consent", makeConsentHandler(fabClient))

	srv := &http.Server{
		Addr:         getenv("PORT", ":8085"),
		Handler:      mux,
		TLSConfig:    buildTLSConfig(),
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("token-bridge: listening on %s (TLS 1.3 min)", srv.Addr)
		if err := srv.ListenAndServeTLS(
			getenv("TLS_CERT", "certs/server.crt"),
			getenv("TLS_KEY", "certs/server.key"),
		); err != nil && err != http.ErrServerClosed {
			log.Fatalf("token-bridge: serve: %v", err)
		}
	}()

	<-stop
	log.Println("token-bridge: shutting down …")
	cancel()

	shutCtx, shutCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer shutCancel()
	if err := srv.Shutdown(shutCtx); err != nil {
		log.Printf("token-bridge: shutdown error: %v", err)
	}
	log.Println("token-bridge: stopped")
}

// ─── HTTP handlers ────────────────────────────────────────────────────────────

func makeRunHandler(calc *distribution.Calculator) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Period string `json:"period"`
		}
		// H-02: never return internal error details to client
		if err := decodeJSON(r, &body); err != nil {
			log.Printf("token-bridge: run handler decode error: %v", err)
			http.Error(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if err := calc.RunQuarterlyDistribution(r.Context(), body.Period); err != nil {
			log.Printf("token-bridge: distribution run error: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func makeHistoryHandler(fab *fabric.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		holderHash := r.PathValue("holderHash")
		records, err := fab.GetDistributionHistory(holderHash)
		// H-02: log internal error, return generic message to prevent schema leakage
		if err != nil {
			log.Printf("token-bridge: get distribution history error: %v", err)
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		writeJSON(w, records)
	}
}

func makeAllocateHandler(fab *fabric.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Period       string `json:"period"`
			TotalRevenue string `json:"totalRevenue"` // micro-EURC integer string
		}
		// H-02: never return internal error details to client
		if err := decodeJSON(r, &body); err != nil {
			log.Printf("token-bridge: allocate handler decode error: %v", err)
			http.Error(w, "invalid request body", http.StatusBadRequest)
			return
		}
		txID, err := fab.RecordRevenueAllocation(body.Period, body.TotalRevenue)
		if err != nil {
			log.Printf("token-bridge: record revenue allocation error: %v", err)
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		writeJSON(w, map[string]string{"txID": txID})
	}
}

func makeConsentHandler(fab *fabric.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		holderHash := r.PathValue("holderHash")
		var body struct {
			Granted         bool   `json:"granted"`
			SignatureTxHash string `json:"signatureTxHash"` // channel-1 AdES txID
		}
		// H-02: never return internal error details to client
		if err := decodeJSON(r, &body); err != nil {
			log.Printf("token-bridge: consent handler decode error: %v", err)
			http.Error(w, "invalid request body", http.StatusBadRequest)
			return
		}
		txID, err := fab.RecordHolderConsent(holderHash, body.Granted, body.SignatureTxHash)
		if err != nil {
			log.Printf("token-bridge: record holder consent error: %v", err)
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		writeJSON(w, map[string]string{"txID": txID})
	}
}

// ─── TLS / utilities ──────────────────────────────────────────────────────────

func buildTLSConfig() *tls.Config {
	cfg := &tls.Config{MinVersion: tls.VersionTLS13}
	caCertPath := os.Getenv("CLIENT_CA_CERT")
	if caCertPath == "" {
		return cfg
	}
	pem, err := os.ReadFile(caCertPath)
	if err != nil {
		log.Fatalf("token-bridge: read CLIENT_CA_CERT: %v", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		log.Fatalf("token-bridge: no valid certs in CLIENT_CA_CERT")
	}
	cfg.ClientCAs = pool
	cfg.ClientAuth = tls.RequireAndVerifyClientCert
	return cfg
}

func decodeJSON(r *http.Request, dst any) error {
	if r.Body == nil {
		return fmt.Errorf("empty request body")
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(dst)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("token-bridge: writeJSON: %v", err)
	}
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("token-bridge: required env var %s is not set", key)
	}
	return v
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
