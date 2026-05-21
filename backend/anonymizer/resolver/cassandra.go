package resolver

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"fmt"

	"github.com/gocql/gocql"
	"github.com/nobordershealthcare/anonymizer/config"
)

// CassandraResolver fetches and decrypts encrypted blobs from ScyllaDB.
// ScyllaDB stores AES-256-GCM encrypted blobs keyed by cassandra_row_key.
// Plaintext health data NEVER leaves this function unencrypted.
type CassandraResolver struct {
	session *gocql.Session
	secrets *config.SecretStore
}

func NewCassandraResolver(hosts []string, keyspace string, secrets *config.SecretStore) (*CassandraResolver, error) {
	cluster := gocql.NewCluster(hosts...)
	cluster.Keyspace = keyspace
	cluster.Consistency = gocql.LocalQuorum

	session, err := cluster.CreateSession()
	if err != nil {
		return nil, fmt.Errorf("scylladb connect: %w", err)
	}
	return &CassandraResolver{session: session, secrets: secrets}, nil
}

// FetchBlob retrieves the AES-256-GCM encrypted blob for cassandraKey and
// decrypts it in memory. The plaintext is returned to the caller for
// in-memory XML assembly — it must not be written to disk or logged.
//
// Blob format in ScyllaDB: 12-byte GCM nonce || ciphertext || 16-byte GCM tag
// (standard GCM construction — nonce is stored with the ciphertext).
func (r *CassandraResolver) FetchBlob(ctx context.Context, cassandraKey []byte) ([]byte, error) {
	var encrypted []byte
	err := r.session.Query(
		`SELECT payload FROM health_blobs WHERE row_key = ? LIMIT 1`,
		cassandraKey,
	).WithContext(ctx).Scan(&encrypted)
	if err == gocql.ErrNotFound {
		return nil, fmt.Errorf("blob not found")
	}
	if err != nil {
		return nil, fmt.Errorf("scylladb fetch: %w", err)
	}

	plaintext, err := r.decrypt(encrypted)
	if err != nil {
		return nil, fmt.Errorf("blob decrypt: %w", err)
	}
	return plaintext, nil
}

func (r *CassandraResolver) decrypt(cipherBlob []byte) ([]byte, error) {
	// Minimum: 12 (nonce) + 1 (ciphertext) + 16 (tag) = 29 bytes.
	if len(cipherBlob) < 29 {
		return nil, fmt.Errorf("cipherblob too short")
	}

	secrets := r.secrets.Secrets()
	defer func() {
		// AES key copy was made in Secrets(); zero it after use.
		zeroSlice(secrets.AESKey)
	}()

	block, err := aes.NewCipher(secrets.AESKey)
	if err != nil {
		return nil, fmt.Errorf("aes init: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm init: %w", err)
	}

	nonce := cipherBlob[:12]
	ciphertext := cipherBlob[12:]
	return gcm.Open(nil, nonce, ciphertext, nil)
}

func (r *CassandraResolver) Close() {
	r.session.Close()
}

func zeroSlice(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
