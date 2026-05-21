// Package encryption provides AES-256-GCM encrypt/decrypt for CDR blobs.
//
// Key must be exactly 32 bytes (AES-256).
// Ciphertext format: 12-byte random nonce || GCM ciphertext || 16-byte tag.
// The nonce is prepended so the reader has everything needed to decrypt.
package encryption

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
)

const (
	nonceSize = 12 // standard GCM nonce length
	keySize   = 32 // AES-256: 32 bytes
)

// ErrInvalidKey is returned when the key is not exactly 32 bytes.
var ErrInvalidKey = errors.New("encryption: key must be 32 bytes (AES-256)")

// Encrypt encrypts plaintext with AES-256-GCM using a fresh random nonce.
// Returns nonce || ciphertext || tag. The caller should zero key after use.
func Encrypt(key, plaintext []byte) ([]byte, error) {
	if len(key) != keySize {
		return nil, ErrInvalidKey
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm: %w", err)
	}

	nonce := make([]byte, nonceSize)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("nonce generation: %w", err)
	}

	// Seal appends ciphertext+tag to nonce in one allocation.
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

// Decrypt decrypts a blob produced by Encrypt.
// Returns the plaintext. The caller must zero it after use.
func Decrypt(key, ciphertext []byte) ([]byte, error) {
	if len(key) != keySize {
		return nil, ErrInvalidKey
	}
	if len(ciphertext) < nonceSize {
		return nil, errors.New("encryption: ciphertext too short")
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm: %w", err)
	}

	nonce := ciphertext[:nonceSize]
	data := ciphertext[nonceSize:]

	plain, err := gcm.Open(nil, nonce, data, nil)
	if err != nil {
		// Do not include ciphertext details in error — avoid oracle attacks.
		return nil, errors.New("encryption: authentication failed")
	}
	return plain, nil
}
