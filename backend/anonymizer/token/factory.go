package token

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync/atomic"

	"golang.org/x/crypto/sha3"
)

// serverEntropy is seeded once at pod start from OS CSPRNG.
// XOR-mixed with each CSPRNG draw before hashing to produce tokens.
var serverEntropy [32]byte
var entropyReady atomic.Bool

// InitEntropy must be called once at startup before any token generation.
func InitEntropy() error {
	if _, err := rand.Read(serverEntropy[:]); err != nil {
		return fmt.Errorf("seed server entropy: %w", err)
	}
	entropyReady.Store(true)
	return nil
}

// Generate returns a 64-char lowercase hex token.
// Construction: crypto/rand(32 bytes) XOR serverEntropy → SHA3-256 → hex.
// SHA3-256 via golang.org/x/crypto/sha3 — never crypto/sha256.
func Generate() (string, error) {
	if !entropyReady.Load() {
		return "", fmt.Errorf("server entropy not initialised")
	}

	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", fmt.Errorf("csprng read: %w", err)
	}

	var mixed [32]byte
	for i := range raw {
		mixed[i] = raw[i] ^ serverEntropy[i]
	}

	digest := sha3.Sum256(mixed[:])
	return hex.EncodeToString(digest[:]), nil
}
