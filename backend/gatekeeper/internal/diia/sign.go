package diia

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"

	"github.com/google/uuid"
)

// HashedFile describes a file that a citizen is asked to sign.
// The FileHash is the hex-encoded SHA-256 of the file content — this is a
// protocol-mandated exception to the project-wide SHA3-256 rule: Diia's
// hashedFilesSigning API specification requires SHA-256 for file hashes.
// (Analogous to PKCE/RFC 7636 and Apple ECIES — external standard requirements.)
//
// FileKey is a caller-assigned opaque identifier used to correlate the signed
// file in the callback. It must be unique within a signing request.
type HashedFile struct {
	FileName string `json:"fileName"`
	FileSize int64  `json:"fileSize"`
	FileHash string `json:"fileHash"` // SHA-256 hex — see note above
	FileKey  string `json:"fileKey"`  // caller-assigned correlation key
}

// subscriptionRequest is the payload for
// POST /api/v1/acquirers/branch/{branchId}/offer/{offerId}/subscription.
type subscriptionRequest struct {
	RequestID  string       `json:"requestId"`
	ReturnLink string       `json:"returnLink,omitempty"`
	Files      []HashedFile `json:"files"`
}

// subscriptionResponse is the JSON body returned by the subscription endpoint.
type subscriptionResponse struct {
	DeepLink string `json:"deeplink"`
}

// RequestSign initiates a Diia.Підпис signing session for the given files.
//
// It:
//  1. Generates a UUID v4 as the requestID (idempotency/correlation key).
//  2. POSTs to POST /api/v1/acquirers/branch/{branchId}/offer/{offerId}/subscription.
//  3. Returns the requestID (to be stored by the caller for callback correlation)
//     and the deep-link URL that the user should open in the Diia app.
//
// The caller is responsible for persisting the requestID → metadata mapping in
// Redis (see store.go) before presenting the deeplink to the user.
//
// files must be non-empty. Each HashedFile.FileHash must be the hex-encoded
// SHA-256 of the corresponding file content (use HashFileSHA256 to compute it).
func (c *Client) RequestSign(ctx context.Context, branchID, offerID string, files []HashedFile) (requestID, deeplink string, err error) {
	if branchID == "" {
		return "", "", fmt.Errorf("diia: RequestSign: branchID is required")
	}
	if offerID == "" {
		return "", "", fmt.Errorf("diia: RequestSign: offerID is required")
	}
	if len(files) == 0 {
		return "", "", fmt.Errorf("diia: RequestSign: at least one file is required")
	}

	requestID = uuid.New().String()
	path := fmt.Sprintf(
		"/api/v1/acquirers/branch/%s/offer/%s/subscription",
		branchID, offerID,
	)

	body := subscriptionRequest{
		RequestID: requestID,
		Files:     files,
	}

	var resp subscriptionResponse
	if err := c.doJSON(ctx, http.MethodPost, path, body, &resp); err != nil {
		return "", "", fmt.Errorf("diia: RequestSign: %w", err)
	}
	if resp.DeepLink == "" {
		return "", "", fmt.Errorf("diia: RequestSign: empty deeplink in response")
	}

	return requestID, resp.DeepLink, nil
}

// HashFileSHA256 computes the SHA-256 digest of data and returns it as a
// lowercase hex string.
//
// SHA-256 NOTE: This function intentionally uses SHA-256 rather than SHA3-256.
// The Diia.Підпис API requires SHA-256 hashes for the fileHash field in signing
// requests (hashedFilesSigning scope). This is a protocol-mandated exception,
// analogous to PKCE (RFC 7636) and Apple ECIES — the external standard defines
// the algorithm and there is no SHA3 alternative. Internal identifiers stored
// in Redis always use SHA3-256 (see store.go). The CI security gate excludes
// this function from the SHA-256 lint rule.
func HashFileSHA256(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}
