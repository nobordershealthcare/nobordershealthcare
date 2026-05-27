package config

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"os"

	vault "github.com/hashicorp/vault/api"
)

// k8sTokenPath returns the Kubernetes service account JWT path.
// Configurable via K8S_SA_TOKEN_PATH env var; defaults to the standard k8s mount.
func k8sTokenPath() string {
	if p := os.Getenv("K8S_SA_TOKEN_PATH"); p != "" {
		return p
	}
	return "/var/run/secrets/kubernetes.io/serviceaccount/token"
}

// VaultClient wraps the HashiCorp Vault API client with helpers specific to
// the normalization service. Authenticates via the Kubernetes auth method —
// no static credentials are used.
type VaultClient struct {
	client *vault.Client
}

// NewVaultClient authenticates to Vault using the k8s service account token
// and returns a ready-to-use VaultClient. Called once at service startup.
func NewVaultClient(addr, role string) (*VaultClient, error) {
	cfg := vault.DefaultConfig()
	cfg.Address = addr
	// TLS config: use the system trust store. Vault address must be HTTPS.
	if err := cfg.ConfigureTLS(&vault.TLSConfig{Insecure: false}); err != nil {
		return nil, fmt.Errorf("vault TLS config: %w", err)
	}

	client, err := vault.NewClient(cfg)
	if err != nil {
		return nil, fmt.Errorf("vault client init: %w", err)
	}

	// Read the k8s service account JWT.
	saToken, err := os.ReadFile(k8sTokenPath())
	if err != nil {
		return nil, fmt.Errorf("vault: read k8s SA token: %w", err)
	}

	// Authenticate via the Kubernetes auth backend using Logical().Write().
	// This works with github.com/hashicorp/vault/api without additional deps.
	secret, err := client.Logical().Write("auth/kubernetes/login", map[string]interface{}{
		"role": role,
		"jwt":  string(saToken),
	})
	if err != nil {
		return nil, fmt.Errorf("vault k8s auth: %w", err)
	}
	if secret == nil || secret.Auth == nil {
		return nil, fmt.Errorf("vault k8s auth: empty auth response")
	}

	client.SetToken(secret.Auth.ClientToken)
	return &VaultClient{client: client}, nil
}

// FetchEdDSAPublicKey retrieves the gatekeeper's Ed25519 public key from Vault.
// Called once at startup to configure JWT verification in the FHIR middleware.
func (v *VaultClient) FetchEdDSAPublicKey() (ed25519.PublicKey, error) {
	secret, err := v.client.KVv2("secret").Get(context.Background(), "gatekeeper/eddsa-public-key")
	if err != nil {
		return nil, fmt.Errorf("vault fetch EdDSA key: %w", err)
	}
	if secret == nil || secret.Data == nil {
		return nil, fmt.Errorf("vault fetch EdDSA key: no data returned")
	}

	rawB64, ok := secret.Data["public_key"].(string)
	if !ok || rawB64 == "" {
		return nil, fmt.Errorf("vault fetch EdDSA key: missing or invalid 'public_key' field")
	}

	keyBytes, err := base64.StdEncoding.DecodeString(rawB64)
	if err != nil {
		return nil, fmt.Errorf("vault fetch EdDSA key: base64 decode: %w", err)
	}
	if len(keyBytes) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("vault fetch EdDSA key: expected %d bytes, got %d",
			ed25519.PublicKeySize, len(keyBytes))
	}
	return ed25519.PublicKey(keyBytes), nil
}

// FetchAESKey retrieves the per-patient AES-256 key (32 bytes) from Vault.
// userHash must be the SHA3-256(userID): exactly 64 lowercase hex chars.
// The caller MUST zero the returned slice after use.
func (v *VaultClient) FetchAESKey(ctx context.Context, userHash string) ([]byte, error) {
	if len(userHash) != 64 {
		return nil, fmt.Errorf("vault FetchAESKey: invalid userHash length %d (want 64)", len(userHash))
	}

	path := "cdr-keys/" + userHash
	secret, err := v.client.KVv2("secret").Get(ctx, path)
	if err != nil {
		// Log only the hash prefix — never the full userHash in an error that
		// might propagate to logs.
		return nil, fmt.Errorf("vault FetchAESKey user=%s...: %w", userHash[:8], err)
	}
	if secret == nil || secret.Data == nil {
		return nil, fmt.Errorf("vault FetchAESKey user=%s...: no data returned", userHash[:8])
	}

	rawB64, ok := secret.Data["aes_key"].(string)
	if !ok || rawB64 == "" {
		return nil, fmt.Errorf("vault FetchAESKey user=%s...: missing 'aes_key' field", userHash[:8])
	}

	keyBytes, err := base64.StdEncoding.DecodeString(rawB64)
	if err != nil {
		return nil, fmt.Errorf("vault FetchAESKey user=%s...: base64 decode: %w", userHash[:8], err)
	}
	if len(keyBytes) != 32 {
		return nil, fmt.Errorf("vault FetchAESKey: expected 32 bytes, got %d", len(keyBytes))
	}
	return keyBytes, nil
}
