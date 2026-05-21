package media

import (
	"context"
	"fmt"
	"net/url"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"github.com/nobordershealthcare/anonymizer/config"
)

const presignedTTL = 120 * time.Second

// PresignedGenerator creates MinIO pre-signed GET URLs for health record objects.
type PresignedGenerator struct {
	client *minio.Client
	bucket string
}

// NewPresignedGenerator builds a MinIO client using credentials sourced from
// the Vault Agent sidecar (via SecretStore). The MinIO SDK signs requests
// using AWS Signature V4 (HMAC-SHA256). That is a wire-protocol requirement
// and is entirely separate from this project's SHA3-256 hashing standard,
// which governs OUR tokens, audit log identifiers, and document hashes.
// The signing secret from Vault MUST NOT be logged, traced, or written to
// any persistent store — it is consumed here in memory only.
func NewPresignedGenerator(endpoint, bucket string, secrets *config.SecretStore) (*PresignedGenerator, error) {
	s := secrets.Secrets()
	defer zeroBytes(s.MinIOSigningSecret)

	// MinIOSigningSecret is the raw secret key material for MinIO access.
	// Vault delivers it as bytes; MinIO credentials expect a string.
	// We decode it here, use it once, and never store it beyond this function.
	secretStr := string(s.MinIOSigningSecret)

	u, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("minio endpoint parse: %w", err)
	}
	useSSL := u.Scheme == "https"

	client, err := minio.New(u.Host, &minio.Options{
		Creds:  credentials.NewStaticV4("anonymizer", secretStr, ""),
		Secure: useSSL,
	})
	if err != nil {
		return nil, fmt.Errorf("minio client init: %w", err)
	}

	return &PresignedGenerator{client: client, bucket: bucket}, nil
}

// GenerateURL returns a pre-signed GET URL for objectKey with a 120-second TTL.
// The URL is single-use — callers MUST register it in Redis via SingleUseStore
// immediately after calling this function (see singleuse.go).
func (g *PresignedGenerator) GenerateURL(ctx context.Context, objectKey string) (string, error) {
	u, err := g.client.PresignedGetObject(ctx, g.bucket, objectKey, presignedTTL, nil)
	if err != nil {
		return "", fmt.Errorf("presign object: %w", err)
	}
	return u.String(), nil
}

func zeroBytes(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
