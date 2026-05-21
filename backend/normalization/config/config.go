// Package config loads service configuration from environment variables.
// No secrets are read here — secrets come exclusively via Vault Agent sidecar
// or k8s Secret volumes mounted at runtime.
package config

import (
	"fmt"
	"os"
	"strings"
)

// Config holds all runtime configuration for the normalization service.
type Config struct {
	// Kafka ─────────────────────────────────────────────────────────────────
	KafkaBrokers []string // KAFKA_BROKERS comma-separated

	// ScyllaDB ───────────────────────────────────────────────────────────────
	ScyllaHosts []string // SCYLLA_HOSTS comma-separated
	ScyllaCert  string   // SCYLLA_CERT path to mTLS client cert
	ScyllaKey   string   // SCYLLA_KEY  path to mTLS client private key
	ScyllaCA    string   // SCYLLA_CA   path to CA certificate

	// FHIR HTTP API ──────────────────────────────────────────────────────────
	ListenAddr string // FHIR_LISTEN_ADDR e.g. ":8080"

	// Vault ──────────────────────────────────────────────────────────────────
	VaultAddr string // VAULT_ADDR e.g. "https://vault.internal:8200"
	VaultRole string // VAULT_ROLE Kubernetes auth role name

	// Hyperledger Fabric audit ───────────────────────────────────────────────
	FabricEndpoint    string // FABRIC_ENDPOINT gRPC host:port
	FabricMSPID       string // FABRIC_MSP_ID
	FabricCertPath    string // FABRIC_CERT_PATH
	FabricKeyPath     string // FABRIC_KEY_PATH
	FabricTLSCertPath string // FABRIC_TLS_CERT_PATH
	FabricChannel     string // FABRIC_CHANNEL default "mychannel"
	FabricChaincode   string // FABRIC_CHAINCODE default "audit"
}

// Load reads all required configuration from env vars.
// Returns an error listing every missing variable so misconfigured pods
// fail loudly at startup rather than silently misbehaving.
func Load() (*Config, error) {
	var missing []string

	get := func(key string) string {
		v := os.Getenv(key)
		if v == "" {
			missing = append(missing, key)
		}
		return v
	}

	getOptional := func(key, def string) string {
		if v := os.Getenv(key); v != "" {
			return v
		}
		return def
	}

	c := &Config{
		KafkaBrokers: splitCSV(get("KAFKA_BROKERS")),
		ScyllaHosts:  splitCSV(get("SCYLLA_HOSTS")),
		ScyllaCert:   get("SCYLLA_CERT"),
		ScyllaKey:    get("SCYLLA_KEY"),
		ScyllaCA:     get("SCYLLA_CA"),
		ListenAddr:   getOptional("FHIR_LISTEN_ADDR", ":8080"),
		VaultAddr:    get("VAULT_ADDR"),
		VaultRole:    get("VAULT_ROLE"),

		FabricEndpoint:    get("FABRIC_ENDPOINT"),
		FabricMSPID:       get("FABRIC_MSP_ID"),
		FabricCertPath:    get("FABRIC_CERT_PATH"),
		FabricKeyPath:     get("FABRIC_KEY_PATH"),
		FabricTLSCertPath: get("FABRIC_TLS_CERT_PATH"),
		FabricChannel:     getOptional("FABRIC_CHANNEL", "mychannel"),
		FabricChaincode:   getOptional("FABRIC_CHAINCODE", "audit"),
	}

	if len(missing) > 0 {
		return nil, fmt.Errorf("config: missing required env vars: %s", strings.Join(missing, ", "))
	}
	return c, nil
}

func splitCSV(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}
