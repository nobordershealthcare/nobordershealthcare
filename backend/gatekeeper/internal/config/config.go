package config

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"
)

// Config holds all runtime configuration. Values come from environment variables
// injected by k8s secrets / Vault agent — never hardcoded.
type Config struct {
	// Server
	ListenAddr string
	TLSCert    string // path to PEM cert (rotated every 24h by cert-manager)
	TLSKey     string // path to PEM key
	ClientCA   string // path to CA bundle for mTLS client verification

	// Ed25519 signing key (PEM paths — loaded from Vault)
	JWTPrivKeyPath string
	JWTPubKeyPath  string
	JWTMaxAge      time.Duration // enforced max, not just token exp claim

	// Redis (jti replay store)
	RedisAddr     string
	RedisPassword string
	RedisTLSCert  string
	RedisTLSKey   string
	RedisCA       string

	// Hyperledger Fabric
	FabricEndpoint    string
	FabricMSPID       string
	FabricCertPath    string
	FabricKeyPath     string
	FabricTLSCAPath   string
	FabricChannelName string
	FabricChaincode   string
	FabricTimeout     time.Duration

	// HSM (PKCS#11 for salt retrieval)
	HSMLibPath string
	HSMSlotPin string
	HSMKeyLabel string
}

func Load() (*Config, error) {
	c := &Config{
		ListenAddr:        envOrDefault("LISTEN_ADDR", ":8443"),
		TLSCert:           mustEnv("TLS_CERT_PATH"),
		TLSKey:            mustEnv("TLS_KEY_PATH"),
		ClientCA:          mustEnv("CLIENT_CA_PATH"),
		JWTPrivKeyPath:    mustEnv("JWT_PRIV_KEY_PATH"),
		JWTPubKeyPath:     mustEnv("JWT_PUB_KEY_PATH"),
		JWTMaxAge:         15 * time.Minute, // non-negotiable per architecture
		RedisAddr:         mustEnv("REDIS_ADDR"),
		RedisPassword:     mustEnv("REDIS_PASSWORD"),
		RedisTLSCert:      mustEnv("REDIS_TLS_CERT_PATH"),
		RedisTLSKey:       mustEnv("REDIS_TLS_KEY_PATH"),
		RedisCA:           mustEnv("REDIS_CA_PATH"),
		FabricEndpoint:    mustEnv("FABRIC_ENDPOINT"),
		FabricMSPID:       mustEnv("FABRIC_MSP_ID"),
		FabricCertPath:    mustEnv("FABRIC_CERT_PATH"),
		FabricKeyPath:     mustEnv("FABRIC_KEY_PATH"),
		FabricTLSCAPath:   mustEnv("FABRIC_TLS_CA_PATH"),
		FabricChannelName: mustEnv("FABRIC_CHANNEL"),
		FabricChaincode:   mustEnv("FABRIC_CHAINCODE"),
		FabricTimeout:     fabricTimeout(),
		HSMLibPath:        mustEnv("HSM_LIB_PATH"),
		HSMSlotPin:        mustEnv("HSM_SLOT_PIN"),
		HSMKeyLabel:       mustEnv("HSM_KEY_LABEL"),
	}
	return c, nil
}

// MutualTLSConfig returns a tls.Config that enforces mTLS with TLS 1.3 minimum.
// No TLS 1.2 fallback — per architecture security requirements.
func (c *Config) MutualTLSConfig() (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(c.TLSCert, c.TLSKey)
	if err != nil {
		return nil, fmt.Errorf("load server cert: %w", err)
	}
	caPool, err := loadCertPool(c.ClientCA)
	if err != nil {
		return nil, fmt.Errorf("load client CA: %w", err)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientCAs:    caPool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		MinVersion:   tls.VersionTLS13,
	}, nil
}

func loadCertPool(caPath string) (*x509.CertPool, error) {
	pem, err := os.ReadFile(caPath)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, errors.New("no valid certs in CA bundle")
	}
	return pool, nil
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		panic(fmt.Sprintf("required env var %s is not set", key))
	}
	return v
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func fabricTimeout() time.Duration {
	s := os.Getenv("FABRIC_TIMEOUT_MS")
	if s == "" {
		return 500 * time.Millisecond
	}
	ms, err := strconv.Atoi(s)
	if err != nil || ms <= 0 {
		return 500 * time.Millisecond
	}
	return time.Duration(ms) * time.Millisecond
}
