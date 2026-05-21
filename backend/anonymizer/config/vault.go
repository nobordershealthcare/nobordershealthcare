package config

import (
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"sync"

	"github.com/fsnotify/fsnotify"
	"golang.org/x/crypto/sha3"
)

// VaultSecrets is the parsed representation of the Vault Agent-rendered
// JSON file on the tmpfs mount. All fields are byte slices so they can
// be zeroed on rotation.
type VaultSecrets struct {
	// AES-256 key for ScyllaDB blob decryption (32 bytes).
	AESKey []byte

	// HMAC signing secret for MinIO pre-signed URLs.
	// This secret is used internally by the MinIO SDK for AWS Signature V4
	// (HMAC-SHA256). That is a wire-protocol requirement and is separate
	// from the project-wide SHA3-256 hashing standard, which applies only
	// to OUR tokens, audit logs, and identifiers — not to MinIO SDK internals.
	// This value MUST NOT be logged, traced, or written to any persistent store.
	MinIOSigningSecret []byte
}

// vaultJSON is the raw shape of the Vault Agent-rendered file.
// DocIDMap maps SHA3-256(docID) hex strings to cassandra_row_keys.
// This field is handled separately (see DocIDMap below) because it needs
// its own mutex-guarded swap lifecycle.
type vaultJSON struct {
	AESKeyHex          string            `json:"aes_key"`
	MinIOSecretHex     string            `json:"minio_signing_secret"`
	DocIDMap           map[string]string `json:"docid_map"`
}

// SecretStore holds the live in-memory state injected from Vault.
// All mutations go through swapDocIDMap / swapSecrets under their respective locks.
type SecretStore struct {
	mu      sync.RWMutex
	secrets VaultSecrets

	mapMu  sync.RWMutex
	docIDs map[string][]byte // SHA3-256 hex → cassandra_row_key bytes
}

// NewSecretStore loads secrets from the Vault tmpfs path and starts the
// fsnotify watcher for live rotation. Returns a fatal error if the initial
// load fails — the pod must not start without the map.
func NewSecretStore(vaultPath string) (*SecretStore, error) {
	ss := &SecretStore{}
	if err := ss.load(vaultPath); err != nil {
		return nil, fmt.Errorf("vault initial load: %w", err)
	}

	go ss.watch(vaultPath)
	return ss, nil
}

// Secrets returns a snapshot of the current non-map secrets.
// Callers must not retain the returned struct across request boundaries.
func (ss *SecretStore) Secrets() VaultSecrets {
	ss.mu.RLock()
	defer ss.mu.RUnlock()
	return ss.secrets
}

// ResolveDocID looks up a cassandra_row_key by SHA3-256(docID) hex.
// Returns nil if the key is not in the current map.
func (ss *SecretStore) ResolveDocID(hashHex string) []byte {
	ss.mapMu.RLock()
	v := ss.docIDs[hashHex]
	ss.mapMu.RUnlock()
	return v
}

// load reads and parses the Vault tmpfs file, then atomically swaps both
// the secrets and the docID map. On failure the existing state is unchanged.
func (ss *SecretStore) load(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read vault file: %w", err)
	}
	defer zeroBytes(data)

	var raw vaultJSON
	if err := json.Unmarshal(data, &raw); err != nil {
		return fmt.Errorf("parse vault json: %w", err)
	}

	aesKey, err := decodeAndValidateHex(raw.AESKeyHex, 32)
	if err != nil {
		return fmt.Errorf("aes_key: %w", err)
	}
	minioSecret, err := decodeAndValidateHex(raw.MinIOSecretHex, 0)
	if err != nil {
		return fmt.Errorf("minio_signing_secret: %w", err)
	}

	newMap, err := parseDocIDMap(raw.DocIDMap)
	if err != nil {
		zeroBytes(aesKey)
		zeroBytes(minioSecret)
		return fmt.Errorf("docid_map: %w", err)
	}

	// Swap secrets.
	ss.mu.Lock()
	oldSecrets := ss.secrets
	ss.secrets = VaultSecrets{AESKey: aesKey, MinIOSigningSecret: minioSecret}
	ss.mu.Unlock()
	zeroBytes(oldSecrets.AESKey)
	zeroBytes(oldSecrets.MinIOSigningSecret)

	// Swap docID map — zero old values before releasing.
	ss.mapMu.Lock()
	oldMap := ss.docIDs
	ss.docIDs = newMap
	ss.mapMu.Unlock()
	zeroMapValues(oldMap)

	return nil
}

// watch blocks on fsnotify events for the Vault tmpfs file.
// On a write event it attempts a live rotation; on failure it keeps the
// current map live and emits a WARN log (hashed content, never raw).
func (ss *SecretStore) watch(path string) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		slog.Error("fsnotify init failed — live vault rotation disabled", "err", err)
		return
	}
	defer watcher.Close()

	if err := watcher.Add(path); err != nil {
		slog.Error("fsnotify watch failed — live vault rotation disabled", "path", path, "err", err)
		return
	}

	for {
		select {
		case event, ok := <-watcher.Events:
			if !ok {
				return
			}
			if event.Has(fsnotify.Write) || event.Has(fsnotify.Create) {
				if err := ss.load(path); err != nil {
					data, _ := os.ReadFile(path)
					h := sha3.Sum256(data)
					zeroBytes(data)
					slog.Warn("vault live rotation failed — keeping current map",
						"file_sha3", hex.EncodeToString(h[:]),
						"err", err)
				} else {
					slog.Info("vault secrets rotated successfully")
				}
			}
		case err, ok := <-watcher.Errors:
			if !ok {
				return
			}
			slog.Error("fsnotify error", "err", err)
		}
	}
}

func parseDocIDMap(raw map[string]string) (map[string][]byte, error) {
	out := make(map[string][]byte, len(raw))
	for k, v := range raw {
		if len(k) != 64 {
			return nil, fmt.Errorf("docid key %q: must be 64 lowercase hex chars", k)
		}
		if _, err := hex.DecodeString(k); err != nil {
			return nil, fmt.Errorf("docid key %q: not valid hex", k)
		}
		rowKey, err := hex.DecodeString(v)
		if err != nil {
			return nil, fmt.Errorf("docid value for key %q: not valid hex", k)
		}
		out[k] = rowKey
	}
	return out, nil
}

func decodeAndValidateHex(s string, expectedBytes int) ([]byte, error) {
	b, err := hex.DecodeString(s)
	if err != nil {
		return nil, fmt.Errorf("not valid hex: %w", err)
	}
	if expectedBytes > 0 && len(b) != expectedBytes {
		return nil, fmt.Errorf("expected %d bytes, got %d", expectedBytes, len(b))
	}
	return b, nil
}

func zeroBytes(b []byte) {
	subtle.ConstantTimeCopy(1, b, make([]byte, len(b)))
}

func zeroMapValues(m map[string][]byte) {
	for k := range m {
		zeroBytes(m[k])
	}
}
