package resolver

import (
	"encoding/hex"
	"fmt"

	"github.com/nobordershealthcare/anonymizer/config"
)

// DocIDResolver resolves SHA3-256(docID) hex strings to cassandra_row_keys
// using the in-memory map held by the SecretStore. The map is sourced from
// the Vault Agent sidecar and MUST NEVER be written to disk or any database.
// If the pod restarts, the map is gone — callers must re-authenticate.
type DocIDResolver struct {
	store *config.SecretStore
}

func NewDocIDResolver(store *config.SecretStore) *DocIDResolver {
	return &DocIDResolver{store: store}
}

// Resolve returns the cassandra_row_key for the given SHA3-256(docID) hex.
// Returns ErrDocIDNotFound if the hash is absent from the current map.
// The returned slice is a copy — the caller may use it freely.
//
// Validation: the hash must be exactly 64 lowercase hex characters.
// This is the project standard: all hash inputs validated before acceptance.
func (r *DocIDResolver) Resolve(hashHex string) ([]byte, error) {
	if err := validateHashHex(hashHex); err != nil {
		return nil, err
	}

	raw := r.store.ResolveDocID(hashHex)
	if raw == nil {
		return nil, ErrDocIDNotFound
	}

	// Return a copy — the backing slice stays in the in-memory map.
	out := make([]byte, len(raw))
	copy(out, raw)
	return out, nil
}

// validateHashHex enforces: 64 chars, lowercase hex.
// See CLAUDE.md: "All hash inputs: validated as 64 lowercase hex chars before acceptance."
func validateHashHex(s string) error {
	if len(s) != 64 {
		return fmt.Errorf("hash must be 64 hex chars, got %d", len(s))
	}
	b, err := hex.DecodeString(s)
	if err != nil || len(b) != 32 {
		return fmt.Errorf("hash is not valid lowercase hex")
	}
	// Reject uppercase — hex.DecodeString accepts both but the project standard
	// requires lowercase only so the comparison against map keys is unambiguous.
	for _, c := range s {
		if c >= 'A' && c <= 'F' {
			return fmt.Errorf("hash must be lowercase hex")
		}
	}
	return nil
}

var ErrDocIDNotFound = fmt.Errorf("docID hash not found in current map")
