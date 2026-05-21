package auth

import (
	"encoding/hex"
	"errors"
	"fmt"
	"runtime"

	"golang.org/x/crypto/sha3"
)

// HSM abstracts PKCS#11 salt retrieval. The salt never leaves the HSM in
// plaintext beyond the duration of a single AuthenticateAndHash call.
type HSM interface {
	// GetUserSalt returns the per-user salt bytes for the given user identifier.
	// The returned slice is owned by the caller and must be zeroed after use.
	GetUserSalt(plainUserID []byte) ([]byte, error)
}

// Authenticator holds dependencies for the authentication flow.
type Authenticator struct {
	hsm HSM
}

func NewAuthenticator(hsm HSM) *Authenticator {
	return &Authenticator{hsm: hsm}
}

// AuthenticateAndHash derives SHA3-256(per-user-salt + userID) and returns the
// 64-character lowercase hex digest. The plainUserID slice and the salt are
// zeroed before returning — callers must pass a mutable []byte and must not
// retain any string copy of the plaintext ID before calling.
//
// Invariants enforced:
//   - plainUserID is zeroed in defer regardless of error path
//   - salt returned by HSM is zeroed in defer
//   - intermediate concatenation buffer is zeroed in defer
//   - result is validated to be exactly 64 hex chars (SHA3-256 = 32 bytes)
func (a *Authenticator) AuthenticateAndHash(plainUserID []byte) (string, error) {
	if len(plainUserID) == 0 {
		return "", errors.New("plainUserID must not be empty")
	}

	salt, err := a.hsm.GetUserSalt(plainUserID)
	if err != nil {
		// Zero what we have before returning
		zeroBytes(plainUserID)
		return "", fmt.Errorf("hsm salt lookup: %w", err)
	}

	// Concatenate into a single owned buffer — never via string concatenation
	// which would create an intermediate immutable string in Go's string intern pool.
	buf := make([]byte, len(salt)+len(plainUserID))
	copy(buf, salt)
	copy(buf[len(salt):], plainUserID)

	defer func() {
		zeroBytes(buf)
		zeroBytes(salt)
		zeroBytes(plainUserID)
		// KeepAlive prevents the compiler from treating the zeroing writes as dead
		// code and eliding them (the values are never read after this point).
		runtime.KeepAlive(buf)
		runtime.KeepAlive(salt)
		runtime.KeepAlive(plainUserID)
	}()

	h := sha3.New256()
	if _, err := h.Write(buf); err != nil {
		return "", fmt.Errorf("sha3 write: %w", err)
	}
	digest := h.Sum(nil)

	result := hex.EncodeToString(digest)
	if len(result) != 64 {
		// Invariant: SHA3-256 always produces 32 bytes = 64 hex chars.
		// A violation here means something is badly wrong with the runtime.
		return "", errors.New("hash output length invariant violated")
	}
	return result, nil
}

func zeroBytes(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

// validateHash enforces the 64-char lowercase hex invariant for all hash inputs.
// SHA3-256 produces 32 bytes = 64 hex chars. Anything else is rejected.
func validateHash(h string) error {
	if len(h) != 64 {
		return fmt.Errorf("expected 64 hex chars, got %d", len(h))
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return fmt.Errorf("non-lowercase-hex character: %q", c)
		}
	}
	return nil
}
