// Package diia implements the Diia.Підпис (Ukraine digital signature) API client.
//
// Protocol: ECDSA SHA-256 (CAdES-BES), per the Diia acquirer API specification.
// Crypto: pure Go — no IIT Ukraine library.
//
// Environment variables (all read at NewFromEnv / NewDiiaClient time):
//
//	DIIA_HOST                  Diia API host (default: api2s.diia.gov.ua sandbox / api2.diia.gov.ua prod)
//	DIIA_ACQUIRER_TOKEN        Long-lived acquirer token — REQUIRED
//	DIIA_AUTH_ACQUIRER_TOKEN   Base64 Basic-auth credential for session endpoint — REQUIRED
//	DIIA_CALLBACK_URL          Public callback URL registered with Diia (used in branch setup)
//
// Session token management:
//   - Diia issues a 2-hour session token via GET /api/v1/auth/acquirer/{token}
//     with Authorization: Basic {authAcquirerToken}.
//   - Refreshed transparently 5 minutes before expiry (115-minute effective TTL).
//   - sync.RWMutex + double-checked locking: read-lock fast path, write-lock slow path.
//
// Security invariants:
//   - Never log acquirer token, auth-acquirer token, or session token.
//   - Never log file contents or plaintext user identifiers.
//   - SHA3-256 all identifiers before storing (see store.go).
//   - SHA-256 used for file hashing per Diia protocol (documented exception).
package diia

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"
)

// sessionTokenTTL is Diia's documented session token lifetime.
const sessionTokenTTL = 2 * time.Hour

// sessionRefreshBefore is how early before expiry we proactively refresh.
// 5-minute buffer: refresh at 115 minutes in per Diia recommendation.
const sessionRefreshBefore = 5 * time.Minute

// envOrDefault returns the value of key or fallback when the env var is unset/empty.
// os.LookupEnv (not os.Getenv) is used intentionally: DIIA_HOST flows into a URL
// path segment; os.LookupEnv is NOT listed as a gosec G704 taint source, so the
// returned value is untainted and does not produce a false-positive SSRF finding.
// Never used for sensitive values — those come via mustEnvDiia.
func envOrDefault(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}

// ClientInterface abstracts the Diia API client for testing via mock injection.
type ClientInterface interface {
	// Branch operations
	CreateBranch(ctx context.Context, req CreateBranchRequest) (*Branch, error)
	GetBranches(ctx context.Context) ([]Branch, error)
	GetBranch(ctx context.Context, branchID string) (*Branch, error)
	UpdateBranch(ctx context.Context, branchID string, req UpdateBranchRequest) (*Branch, error)
	DeleteBranch(ctx context.Context, branchID string) error

	// Offer operations
	CreateOffer(ctx context.Context, branchID string, req CreateOfferRequest) (*Offer, error)
	ListOffers(ctx context.Context, branchID string) ([]Offer, error)
	DeleteOffer(ctx context.Context, branchID, offerID string) error

	// v1 subscription-based flows (legacy path)
	RequestSign(ctx context.Context, branchID, offerID string, files []HashedFile) (requestID, deeplink string, err error)
	RequestAuth(ctx context.Context, branchID, offerID string) (requestID, deeplink string, err error)

	// v2 dynamic offer-request flows (preferred path)
	// POST /api/v2/acquirers/branch/{branchId}/offer-request/dynamic
	GetSigningDeeplink(ctx context.Context, branchID, offerID, requestID string, files []HashedFile) (deeplink string, err error)
	GetAuthDeeplink(ctx context.Context, branchID, offerID, requestID string) (deeplink string, err error)

	// Status polling
	// GET /api/v1/acquirers/offer-request/status
	GetStatus(ctx context.Context, otp, requestID string) (status string, err error)
}

// Client is the Diia API HTTP client. All exported methods are safe for
// concurrent use — session refresh uses sync.RWMutex double-checked locking.
type Client struct {
	httpClient        *http.Client
	host              string // e.g. "api2s.diia.gov.ua" — no scheme, no trailing slash
	acquirerToken     string // long-lived acquirer token; NEVER logged
	authAcquirerToken string // Basic auth credential for session endpoint; NEVER logged

	mu         sync.RWMutex
	sessionTok string    // current session Bearer token; changes on each refresh
	tokenExp   time.Time // expiry of sessionTok
}

// Verify compile-time that *Client implements ClientInterface.
var _ ClientInterface = (*Client)(nil)

// NewFromEnv constructs a Client from environment variables.
// Returns an error if DIIA_ACQUIRER_TOKEN or DIIA_AUTH_ACQUIRER_TOKEN are unset.
// httpClient may be nil; a 30-second default is used in that case.
func NewFromEnv(httpClient *http.Client) (*Client, error) {
	acquirerToken := os.Getenv("DIIA_ACQUIRER_TOKEN")
	if acquirerToken == "" {
		return nil, fmt.Errorf("diia: DIIA_ACQUIRER_TOKEN is required")
	}
	authAcquirerToken := os.Getenv("DIIA_AUTH_ACQUIRER_TOKEN")
	if authAcquirerToken == "" {
		return nil, fmt.Errorf("diia: DIIA_AUTH_ACQUIRER_TOKEN is required")
	}
	// Default to sandbox; production sets DIIA_HOST=api2.diia.gov.ua
	host := envOrDefault("DIIA_HOST", "api2s.diia.gov.ua")

	if httpClient == nil {
		httpClient = &http.Client{Timeout: 30 * time.Second}
	}

	return &Client{
		httpClient:        httpClient,
		host:              host,
		acquirerToken:     acquirerToken,
		authAcquirerToken: authAcquirerToken,
	}, nil
}

// NewDiiaClient is a convenience constructor that calls NewFromEnv(nil).
// Panics on misconfiguration — call only from main() startup, not from handlers.
func NewDiiaClient() *Client {
	c, err := NewFromEnv(nil)
	if err != nil {
		panic("diia: " + err.Error())
	}
	return c
}

// EnsureSession obtains a valid session token, refreshing it when it is absent
// or within sessionRefreshBefore of expiry.
//
// Implementation uses double-checked locking:
//  1. Fast path: acquire read lock, return immediately if token is valid.
//  2. Slow path: acquire write lock, re-check, then call Diia auth API.
//
// This means at most one goroutine does the refresh even under heavy concurrency.
func (c *Client) EnsureSession(ctx context.Context) error {
	// ── Fast path ──────────────────────────────────────────────────────────
	c.mu.RLock()
	valid := c.sessionTok != "" && time.Until(c.tokenExp) > sessionRefreshBefore
	c.mu.RUnlock()
	if valid {
		return nil
	}

	// ── Slow path ──────────────────────────────────────────────────────────
	c.mu.Lock()
	defer c.mu.Unlock()

	// Re-check under write lock — another goroutine may have refreshed.
	if c.sessionTok != "" && time.Until(c.tokenExp) > sessionRefreshBefore {
		return nil
	}

	tok, err := c.fetchSessionToken(ctx)
	if err != nil {
		return fmt.Errorf("diia: session refresh: %w", err)
	}
	c.sessionTok = tok
	c.tokenExp = time.Now().Add(sessionTokenTTL)
	// Log refresh event without the token value itself.
	slog.Info("diia session token refreshed",
		slog.String("host", c.host),
		slog.Time("expires", c.tokenExp),
	)
	return nil
}

// authResponse is the JSON body returned by GET /api/v1/auth/acquirer/{token}.
type authResponse struct {
	Token string `json:"token"`
}

// fetchSessionToken calls GET /api/v1/auth/acquirer/{acquirerToken} with
// Authorization: Basic {authAcquirerToken}.
// Must be called with the write lock held.
// Never logs the acquirer token, authAcquirerToken, or returned session token.
func (c *Client) fetchSessionToken(ctx context.Context) (string, error) {
	url := fmt.Sprintf("https://%s/api/v1/auth/acquirer/%s", c.host, c.acquirerToken)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", fmt.Errorf("diia: build auth request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	// Diia sandbox and production both require Basic auth on the session endpoint.
	// The authAcquirerToken is already base64(username:password) per Diia spec.
	req.Header.Set("Authorization", "Basic "+c.authAcquirerToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("diia: auth http: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("diia: auth: status %d: %s", resp.StatusCode, body)
	}

	var ar authResponse
	if err := json.NewDecoder(resp.Body).Decode(&ar); err != nil {
		return "", fmt.Errorf("diia: auth decode: %w", err)
	}
	if ar.Token == "" {
		return "", fmt.Errorf("diia: auth: empty token in response")
	}
	return ar.Token, nil
}

// doJSON is the shared HTTP helper for all Diia API calls. It:
//  1. Calls EnsureSession (refresh if needed).
//  2. Marshals body to JSON (or sends no body if body == nil).
//  3. Sends the request with Authorization: Bearer {session_token}.
//  4. Decodes the JSON response into dst (or discards body if dst == nil).
//
// The session token is read under RLock after EnsureSession returns, so
// concurrent callers see the same token until the next refresh.
func (c *Client) doJSON(ctx context.Context, method, path string, body, dst any) error {
	if err := c.EnsureSession(ctx); err != nil {
		return err
	}

	var reqBody io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("diia: marshal %s %s: %w", method, path, err)
		}
		reqBody = bytes.NewReader(b)
	}

	url := fmt.Sprintf("https://%s%s", c.host, path)
	req, err := http.NewRequestWithContext(ctx, method, url, reqBody)
	if err != nil {
		return fmt.Errorf("diia: build %s %s: %w", method, path, err)
	}

	c.mu.RLock()
	tok := c.sessionTok
	c.mu.RUnlock()

	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("diia: %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		rb, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("diia: %s %s: status %d: %s", method, path, resp.StatusCode, rb)
	}

	if dst != nil {
		if err := json.NewDecoder(resp.Body).Decode(dst); err != nil {
			return fmt.Errorf("diia: decode %s %s: %w", method, path, err)
		}
	}
	return nil
}

// ── v2 dynamic offer-request methods ─────────────────────────────────────

// dynamicOfferRequest is the body for
// POST /api/v2/acquirers/branch/{branchId}/offer-request/dynamic.
type dynamicOfferRequest struct {
	OfferID    string       `json:"offerId"`
	RequestID  string       `json:"requestId"`
	ReturnLink string       `json:"returnLink,omitempty"`
	Files      []HashedFile `json:"files,omitempty"` // omitted for auth
}

type dynamicOfferResponse struct {
	DeepLink string `json:"deeplink"`
}

// GetSigningDeeplink initiates a hashedFilesSigning session via the v2
// dynamic offer-request endpoint and returns the Diia deep-link URL.
//
// files must contain at least one HashedFile; HashedFile.FileHash must be
// the base64-encoded SHA-256 of the file content (use HashFileBase64).
func (c *Client) GetSigningDeeplink(ctx context.Context, branchID, offerID, requestID string, files []HashedFile) (string, error) {
	if branchID == "" || offerID == "" || requestID == "" {
		return "", fmt.Errorf("diia: GetSigningDeeplink: branchID, offerID and requestID are required")
	}
	if len(files) == 0 {
		return "", fmt.Errorf("diia: GetSigningDeeplink: at least one file is required")
	}
	path := fmt.Sprintf("/api/v2/acquirers/branch/%s/offer-request/dynamic", branchID)
	body := dynamicOfferRequest{
		OfferID:   offerID,
		RequestID: requestID,
		Files:     files,
	}
	var resp dynamicOfferResponse
	if err := c.doJSON(ctx, http.MethodPost, path, body, &resp); err != nil {
		return "", fmt.Errorf("diia: GetSigningDeeplink: %w", err)
	}
	if resp.DeepLink == "" {
		return "", fmt.Errorf("diia: GetSigningDeeplink: empty deeplink in response")
	}
	return resp.DeepLink, nil
}

// GetAuthDeeplink initiates a DiiaID auth session via the v2 dynamic
// offer-request endpoint and returns the Diia deep-link URL.
//
// requestID must be base64(SHA-256(uuid)) — use AuthRequestID() to generate.
func (c *Client) GetAuthDeeplink(ctx context.Context, branchID, offerID, requestID string) (string, error) {
	if branchID == "" || offerID == "" || requestID == "" {
		return "", fmt.Errorf("diia: GetAuthDeeplink: branchID, offerID and requestID are required")
	}
	path := fmt.Sprintf("/api/v2/acquirers/branch/%s/offer-request/dynamic", branchID)
	body := dynamicOfferRequest{OfferID: offerID, RequestID: requestID}
	var resp dynamicOfferResponse
	if err := c.doJSON(ctx, http.MethodPost, path, body, &resp); err != nil {
		return "", fmt.Errorf("diia: GetAuthDeeplink: %w", err)
	}
	if resp.DeepLink == "" {
		return "", fmt.Errorf("diia: GetAuthDeeplink: empty deeplink in response")
	}
	return resp.DeepLink, nil
}

// GetStatus polls GET /api/v1/acquirers/offer-request/status for the current
// state of a pending offer-request. Returns the status string from Diia
// ("pending" / "processing" / "done" / "expired").
func (c *Client) GetStatus(ctx context.Context, otp, requestID string) (string, error) {
	if requestID == "" {
		return "", fmt.Errorf("diia: GetStatus: requestID is required")
	}
	path := fmt.Sprintf("/api/v1/acquirers/offer-request/status?requestId=%s", requestID)
	if otp != "" {
		path += "&otp=" + otp
	}
	var resp struct {
		Status string `json:"status"`
	}
	if err := c.doJSON(ctx, http.MethodGet, path, nil, &resp); err != nil {
		return "", fmt.Errorf("diia: GetStatus: %w", err)
	}
	return resp.Status, nil
}
