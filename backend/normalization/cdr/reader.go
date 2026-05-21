package cdr

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/gocql/gocql"

	"github.com/nobordershealthcare/normalization/encryption"
)

// Reader queries the CDR and returns decrypted Compositions.
// All queries are read-only. Health records are never mutated here.
type Reader struct {
	session    *gocql.Session
	keyFetcher KeyFetcher
}

// NewReader creates a Reader backed by the given session and key fetcher.
func NewReader(session *gocql.Session, kf KeyFetcher) *Reader {
	return &Reader{session: session, keyFetcher: kf}
}

// ObservationsByLOINC returns all Observations for a patient with a given LOINC code.
func (r *Reader) ObservationsByLOINC(ctx context.Context, userHash, loincCode string) ([]*Composition, error) {
	iter := r.session.Query(
		`SELECT doc_hash, source_hash, encrypted_blob, schema_version, review_required, created_at
		 FROM cdr.observations_by_loinc
		 WHERE user_hash = ? AND loinc_code = ?`,
		userHash, loincCode,
	).WithContext(ctx).Iter()

	return r.scanAndDecrypt(ctx, userHash, iter)
}

// CompositionsByType returns all CDR rows of a given type for a patient.
// Used for Condition, MedicationStatement, and AllergyIntolerance queries.
func (r *Reader) CompositionsByType(ctx context.Context, userHash, compositionType string) ([]*Composition, error) {
	iter := r.session.Query(
		`SELECT doc_hash, source_hash, encrypted_blob, schema_version, review_required, created_at
		 FROM cdr.compositions_by_type
		 WHERE user_hash = ? AND composition_type = ?`,
		userHash, compositionType,
	).WithContext(ctx).Iter()

	return r.scanAndDecrypt(ctx, userHash, iter)
}

// AllCompositions returns every CDR row for a patient (IPS summary query).
// This is the most expensive read — called only for the $summary endpoint.
func (r *Reader) AllCompositions(ctx context.Context, userHash string) ([]*Composition, error) {
	iter := r.session.Query(
		`SELECT doc_hash, source_hash, encrypted_blob, schema_version, review_required, created_at
		 FROM cdr.compositions
		 WHERE user_hash = ?`,
		userHash,
	).WithContext(ctx).Iter()

	return r.scanAndDecrypt(ctx, userHash, iter)
}

// scanAndDecrypt iterates over a ScyllaDB result set, decrypts each blob,
// and returns the decoded Compositions. The per-patient AES key is fetched
// once and used for all rows in the result set.
func (r *Reader) scanAndDecrypt(ctx context.Context, userHash string, iter *gocql.Iter) ([]*Composition, error) {
	key, err := r.keyFetcher(ctx, userHash)
	if err != nil {
		return nil, fmt.Errorf("cdr read: key fetch for user %s: %w", userHash[:8]+"...", err)
	}
	defer zeroBytes(key)

	var (
		results       []*Composition
		docHash       string
		sourceHash    string
		encryptedBlob []byte
		schemaVersion int16
		reviewReq     bool
		createdAt     time.Time
	)

	for iter.Scan(&docHash, &sourceHash, &encryptedBlob, &schemaVersion, &reviewReq, &createdAt) {
		plain, err := encryption.Decrypt(key, encryptedBlob)
		if err != nil {
			// Log the hash prefix only — never the key or content.
			return nil, fmt.Errorf("cdr read: decrypt blob doc=%s: %w", docHash[:8]+"...", err)
		}

		var comp Composition
		if err := json.Unmarshal(plain, &comp); err != nil {
			zeroBytes(plain)
			return nil, fmt.Errorf("cdr read: unmarshal composition doc=%s: %w", docHash[:8]+"...", err)
		}
		zeroBytes(plain)

		results = append(results, &comp)
	}

	if err := iter.Close(); err != nil {
		return nil, fmt.Errorf("cdr read: iter close: %w", err)
	}
	return results, nil
}
