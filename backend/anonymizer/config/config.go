package config

import (
	"fmt"
	"os"
	"strconv"
)

// Config holds environment-derived configuration only.
// No secrets live here — secrets are injected by the Vault Agent sidecar
// and loaded by vault.go from the tmpfs mount.
type Config struct {
	// HTTP listener for external (mTLS-required) traffic.
	Port int

	// Internal-only listener for /internal/consume — loopback only, no mTLS.
	// MUST NOT be reachable outside the pod. Istio NetworkPolicy enforces this.
	InternalPort int

	// Path to the Vault Agent-rendered secret file on the tmpfs mount.
	// Populated at pod start; watched by fsnotify for live rotation.
	VaultSecretsPath string

	// Redis Cluster seed addresses (comma-separated host:port pairs).
	RedisAddrs []string

	// ScyllaDB contact points.
	ScyllaHosts []string
	ScyllaKeyspace string

	// MinIO endpoint (scheme://host:port).
	MinIOEndpoint string
	MinIOBucket   string

	// Hyperledger Fabric connection profile path (mounted ConfigMap).
	FabricConnectionProfile string
	FabricChannel           string
	FabricChaincode         string

	// Maximum number of requests before the pod self-terminates.
	MaxRequests int64
}

func Load() (*Config, error) {
	port, err := envInt("PORT", 8080)
	if err != nil {
		return nil, err
	}
	internalPort, err := envInt("INTERNAL_PORT", 8081)
	if err != nil {
		return nil, err
	}
	maxReq, err := envInt("MAX_REQUESTS", 10000)
	if err != nil {
		return nil, err
	}

	redisAddrs := envCSV("REDIS_ADDRS", "redis-cluster.noborders.svc.cluster.local:6379")
	scyllaHosts := envCSV("SCYLLA_HOSTS", "scylladb.noborders.svc.cluster.local")

	return &Config{
		Port:                    port,
		InternalPort:            internalPort,
		VaultSecretsPath:        envStr("VAULT_SECRETS_PATH", "/vault/secrets/anonymizer.json"),
		RedisAddrs:              redisAddrs,
		ScyllaHosts:             scyllaHosts,
		ScyllaKeyspace:          envStr("SCYLLA_KEYSPACE", "anonymizer"),
		MinIOEndpoint:           envStr("MINIO_ENDPOINT", "http://minio.noborders.svc.cluster.local:9000"),
		MinIOBucket:             envStr("MINIO_BUCKET", "health-records"),
		FabricConnectionProfile: envStr("FABRIC_CONNECTION_PROFILE", "/fabric/connection.yaml"),
		FabricChannel:           envStr("FABRIC_CHANNEL", "healthchannel"),
		FabricChaincode:         envStr("FABRIC_CHAINCODE", "accesscontrol"),
		MaxRequests:             int64(maxReq),
	}, nil
}

// envStr reads key via os.LookupEnv (not os.Getenv). Several values returned
// here flow into file paths (VaultSecretsPath, FabricConnectionProfile) or URL
// targets, so using LookupEnv prevents gosec G703/G304/G704 taint findings.
func envStr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) (int, error) {
	v, _ := os.LookupEnv(key)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("env %s: %w", key, err)
	}
	return n, nil
}

func envCSV(key, def string) []string {
	v, _ := os.LookupEnv(key)
	if v == "" {
		v = def
	}
	var out []string
	for _, s := range splitComma(v) {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

func splitComma(s string) []string {
	var parts []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == ',' {
			parts = append(parts, s[start:i])
			start = i + 1
		}
	}
	parts = append(parts, s[start:])
	return parts
}
