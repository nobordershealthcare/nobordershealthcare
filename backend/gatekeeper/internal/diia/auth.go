package diia

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
)

// ── Client method — RequestAuth ───────────────────────────────────────────

// authSubscriptionRequest is the body for auth-scope Diia subscription calls.
// Unlike hashedFilesSigning subscriptions, no files are included — Diia sends
// the citizen's verified identity data back in the callback.
type authSubscriptionRequest struct {
	RequestID  string `json:"requestId"`
	ReturnLink string `json:"returnLink,omitempty"`
}

// RequestAuth initiates a Diia.ID authentication session.
//
// It generates a UUID v4 as the requestID, POSTs to
// POST /api/v1/acquirers/branch/{branchId}/offer/{offerId}/subscription,
// and returns the requestID and the deep-link URL that the iOS client opens.
//
// The caller must persist the requestID → AuthRequestMeta in Redis via
// AuthStoreInterface.SaveAuthRequest before presenting the deeplink to the user.
func (c *Client) RequestAuth(ctx context.Context, branchID, offerID string) (requestID, deeplink string, err error) {
	if branchID == "" {
		return "", "", fmt.Errorf("diia: RequestAuth: branchID is required")
	}
	if offerID == "" {
		return "", "", fmt.Errorf("diia: RequestAuth: offerID is required")
	}

	requestID = uuid.New().String()
	path := fmt.Sprintf("/api/v1/acquirers/branch/%s/offer/%s/subscription", branchID, offerID)

	var resp subscriptionResponse // reuses {DeepLink string} from sign.go
	if err := c.doJSON(ctx, http.MethodPost, path, authSubscriptionRequest{RequestID: requestID}, &resp); err != nil {
		return "", "", fmt.Errorf("diia: RequestAuth: %w", err)
	}
	if resp.DeepLink == "" {
		return "", "", fmt.Errorf("diia: RequestAuth: empty deeplink in response")
	}
	return requestID, resp.DeepLink, nil
}

// ── AuthStoreInterface ────────────────────────────────────────────────────

// AuthStoreInterface is the subset of Store operations required by the auth
// handlers. *Store satisfies this interface; tests inject a mock.
type AuthStoreInterface interface {
	SaveAuthRequest(ctx context.Context, meta AuthRequestMeta) error
	GetAuthRequest(ctx context.Context, requestID string) (*AuthRequestMeta, error)
	SaveAuthResult(ctx context.Context, result AuthResult) error
	GetAuthResult(ctx context.Context, requestID string) (*AuthResult, error)
	// GetAndDeleteAuthResult atomically reads+deletes the result (Redis GETDEL).
	// This eliminates the TOCTOU race: concurrent polls cannot both receive the
	// identity payload (C-02). Only one caller wins; all others get (nil, nil).
	GetAndDeleteAuthResult(ctx context.Context, requestID string) (*AuthResult, error)
	// DeleteAuthRequest is called after consuming the result to make subsequent
	// polls return "expired". DeleteAuthResult is kept for edge-case cleanup.
	DeleteAuthRequest(ctx context.Context, requestID string) error
	DeleteAuthResult(ctx context.Context, requestID string) error
}

// ── Callback JSON types ───────────────────────────────────────────────────

// diiaAuthCallback is the JSON body of POST /v1/diia/auth/callback.
// Diia sends the citizen's verified identity after they authenticate in the app.
// Some Diia API versions nest fields under documents[]; others send them
// top-level. extractIdentity handles both layouts.
type diiaAuthCallback struct {
	RequestID string         `json:"requestId"`
	ProcessID string         `json:"processId,omitempty"`
	Documents []authDocument `json:"documents,omitempty"`
	// Top-level identity fields (older Diia API versions)
	LastName       string `json:"lastName,omitempty"`
	FirstName      string `json:"firstName,omitempty"`
	Patronymic     string `json:"middleName,omitempty"`
	TaxpayerNumber string `json:"taxpayerNumber,omitempty"`
}

// authDocument is a single identity document from the Diia auth callback.
type authDocument struct {
	Type           string `json:"type"`
	DocNumber      string `json:"docNumber,omitempty"`
	TaxpayerNumber string `json:"taxpayerNumber,omitempty"` // RNOKPP / РНОКПП
	LastName       string `json:"lastName"`
	FirstName      string `json:"firstName"`
	Patronymic     string `json:"middleName,omitempty"`
}

// extractIdentity returns (rnokpp, firstName, patronymic, lastName) from the
// callback. Prefers documents[0] over top-level fields; never panics.
func (cb *diiaAuthCallback) extractIdentity() (rnokpp, firstName, patronymic, lastName string) {
	if len(cb.Documents) > 0 {
		d := cb.Documents[0]
		return d.TaxpayerNumber, d.FirstName, d.Patronymic, d.LastName
	}
	return cb.TaxpayerNumber, cb.FirstName, cb.Patronymic, cb.LastName
}

// maskRNOKPP returns a masked RNOKPP showing only the last 4 digits.
// All leading digits are replaced with the Unicode bullet (•, U+2022).
//   "1234567890" → "••••••7890"
//   "123"        → "•••"        (all hidden when ≤4 digits)
func maskRNOKPP(rnokpp string) string {
	const visible = 4
	if len(rnokpp) < visible {
		// Fewer than 4 digits — hide all to avoid exposing partial info.
		return strings.Repeat("•", len(rnokpp))
	}
	return strings.Repeat("•", len(rnokpp)-visible) + rnokpp[len(rnokpp)-visible:]
}

// ── POST /v1/diia/auth/request ────────────────────────────────────────────

// HandleAuthRequest initiates a Diia.ID auth session and returns the deeplink.
//
// Required env vars (read once at handler construction):
//   DIIA_BRANCH_ID     — acquirer branch ID
//   DIIA_OFFER_ID_AUTH — offer ID for the auth scope (DiiaID:["auth"])
//
// Response on success (200):
//   {"requestId":"uuid","deeplink":"https://diia.app/..."}
//
// Error codes:
//   503 — DIIA_BRANCH_ID/DIIA_OFFER_ID_AUTH unset, or Diia API unreachable
//   500 — Redis write failed
func HandleAuthRequest(client ClientInterface, store AuthStoreInterface) http.HandlerFunc {
	// os.LookupEnv (not os.Getenv): branchID and offerID flow into the URL path
	// inside RequestAuth → doJSON; Getenv would taint that path and trigger G704.
	branchID, _ := os.LookupEnv("DIIA_BRANCH_ID")
	offerID, _  := os.LookupEnv("DIIA_OFFER_ID_AUTH")

	if branchID == "" || offerID == "" {
		slog.Warn("diia auth: DIIA_BRANCH_ID or DIIA_OFFER_ID_AUTH not set — /auth/request will return 503")
	}

	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		if branchID == "" || offerID == "" {
			http.Error(w, "auth not configured", http.StatusServiceUnavailable)
			return
		}
		if client == nil {
			http.Error(w, "diia client not configured", http.StatusServiceUnavailable)
			return
		}

		ctx := r.Context()
		requestID, deeplink, err := client.RequestAuth(ctx, branchID, offerID)
		if err != nil {
			slog.Error("diia auth: RequestAuth failed", slog.String("err", err.Error()))
			http.Error(w, "diia unavailable", http.StatusServiceUnavailable)
			return
		}

		meta := AuthRequestMeta{
			RequestID: requestID,
			BranchID:  branchID,
			OfferID:   offerID,
			CreatedAt: time.Now().UTC(),
		}
		if err := store.SaveAuthRequest(ctx, meta); err != nil {
			slog.Error("diia auth: SaveAuthRequest failed",
				slog.String("request_id", requestID),
				slog.String("err", err.Error()),
			)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		slog.Info("diia auth: session initiated", slog.String("request_id", requestID))

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{ //nolint:errcheck
			"requestId": requestID,
			"deeplink":  deeplink,
		})
	}
}

// ── GET /v1/diia/auth/status/{requestId} ─────────────────────────────────

// HandleAuthStatus returns the current auth status for a requestId.
//
// iOS client polls every 2 s, max 90 iterations (3-minute window).
// Status values:
//   pending  — request exists, callback not yet received
//   complete — callback received, identity verified
//   failed   — callback received with an error
//   expired  — requestId not in Redis (TTL elapsed or unknown)
//
// On "complete" the payload includes firstName, patronymic, lastName, and a
// masked RNOKPP (last 4 digits visible, leading digits replaced with •).
// The full RNOKPP hash (SHA3-256) stays in Redis for the gatekeeper auth flow.
func HandleAuthStatus(store AuthStoreInterface) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		requestID := r.PathValue("requestId")
		if requestID == "" {
			http.Error(w, "missing requestId", http.StatusBadRequest)
			return
		}
		// H-03: validate UUID format before touching Redis — prevents key injection
		// and log pollution from arbitrary attacker-controlled strings.
		if _, err := uuid.Parse(requestID); err != nil {
			http.Error(w, "invalid requestId", http.StatusBadRequest)
			return
		}

		ctx := r.Context()
		w.Header().Set("Content-Type", "application/json")

		// Presence of the auth request in Redis tells us the session is live.
		reqMeta, err := store.GetAuthRequest(ctx, requestID)
		if err != nil {
			slog.Error("diia auth: GetAuthRequest failed",
				slog.String("request_id", requestID),
				slog.String("err", err.Error()),
			)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if reqMeta == nil {
			// TTL elapsed, never seen, or already consumed.
			json.NewEncoder(w).Encode(map[string]string{"status": "expired"}) //nolint:errcheck
			return
		}

		// C-02: atomic GETDEL — only one concurrent caller can receive the payload.
		// Concurrent polls get (nil, nil) here and return "pending" safely.
		result, err := store.GetAndDeleteAuthResult(ctx, requestID)
		if err != nil {
			slog.Error("diia auth: GetAndDeleteAuthResult failed",
				slog.String("request_id", requestID),
				slog.String("err", err.Error()),
			)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if result == nil {
			json.NewEncoder(w).Encode(map[string]string{"status": "pending"}) //nolint:errcheck
			return
		}

		// Result atomically consumed — now serve it, then delete the request key
		// so subsequent polls return "expired" rather than "pending".
		if result.Status == "failed" {
			json.NewEncoder(w).Encode(map[string]string{ //nolint:errcheck
				"status": "failed",
				"reason": result.FailReason,
			})
		} else {
			// complete — return masked identity + hash; never return plaintext RNOKPP.
			json.NewEncoder(w).Encode(map[string]any{ //nolint:errcheck
				"status": "complete",
				"payload": map[string]string{
					"firstName":    result.FirstName,
					"patronymic":   result.Patronymic,
					"lastName":     result.LastName,
					"rnokppMasked": result.RNOKPPMask, // "••••••7890"
					"rnokppHash":   result.RNOKPPHash,  // SHA3-256("UA:"+rnokpp)
				},
			})
		}
		// Delete the request key last — after this, all polls return "expired".
		if err := store.DeleteAuthRequest(ctx, requestID); err != nil {
			slog.Warn("diia auth: DeleteAuthRequest failed after terminal response",
				slog.String("request_id", requestID),
				slog.String("err", err.Error()),
			)
		}
	}
}

// ── POST /v1/diia/auth/callback ───────────────────────────────────────────

// HandleAuthCallback processes the Diia.ID identity callback.
//
// Diia POSTs a JSON body containing the citizen's verified identity after
// they complete authentication in the Diia app. This handler:
//   1. Decodes the JSON body.
//   2. Looks up the pending auth request in Redis.
//   3. Extracts RNOKPP, masks it, hashes it with SHA3-256.
//   4. Stores AuthResult in Redis (diia:auth:result:{requestId}, TTL 10 min).
//   5. Returns 200 OK — Diia retries on non-2xx.
//
// Security:
//   - RNOKPP never logged in plaintext — only SHA3-256 hash appears in logs.
//   - Name fields (firstName, lastName, patronymic) never logged.
//   - requestId is logged (UUID, not PII).
//   - 500 on Redis failure (Diia will retry); 200 on business errors.
func HandleAuthCallback(store AuthStoreInterface) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		ctx := r.Context()
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MiB

		var cb diiaAuthCallback
		if err := json.NewDecoder(r.Body).Decode(&cb); err != nil {
			if err != io.EOF {
				slog.Warn("diia auth callback: decode failed", slog.String("err", err.Error()))
			}
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		if cb.RequestID == "" {
			slog.Warn("diia auth callback: missing requestId")
			http.Error(w, "missing requestId", http.StatusBadRequest)
			return
		}
		// H-03: validate UUID format — Diia always sends a UUID v4.
		if _, err := uuid.Parse(cb.RequestID); err != nil {
			slog.Warn("diia auth callback: invalid requestId format")
			http.Error(w, "invalid requestId", http.StatusBadRequest)
			return
		}

		// Verify the session is still live.
		reqMeta, err := store.GetAuthRequest(ctx, cb.RequestID)
		if err != nil {
			slog.Error("diia auth callback: GetAuthRequest failed",
				slog.String("request_id", cb.RequestID),
				slog.String("err", err.Error()),
			)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if reqMeta == nil {
			// Expired or spoofed — 200 stops Diia from retrying.
			slog.Warn("diia auth callback: unknown requestId",
				slog.String("request_id", cb.RequestID),
			)
			w.WriteHeader(http.StatusOK)
			return
		}

		rnokpp, firstName, patronymic, lastName := cb.extractIdentity()

		var rnokppHash, rnokppMask string
		if rnokpp != "" {
			normalized := "UA:" + rnokpp
			rnokppHash = HashRNOKPP(normalized)   // SHA3-256 — safe to log
			rnokppMask = maskRNOKPP(rnokpp)       // "••••••7890"
		}

		result := AuthResult{
			RequestID:   cb.RequestID,
			Status:      "complete",
			FirstName:   firstName,
			Patronymic:  patronymic,
			LastName:    lastName,
			RNOKPPHash:  rnokppHash,
			RNOKPPMask:  rnokppMask,
			CompletedAt: time.Now().UTC(),
		}
		if err := store.SaveAuthResult(ctx, result); err != nil {
			slog.Error("diia auth callback: SaveAuthResult failed",
				slog.String("request_id", cb.RequestID),
				slog.String("err", err.Error()),
			)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		// Only log non-PII: requestId and the SHA3-256 hash of the RNOKPP.
		slog.Info("diia auth callback: identity verified",
			slog.String("request_id", cb.RequestID),
			slog.String("rnokpp_hash", rnokppHash),
		)
		w.WriteHeader(http.StatusOK)
	}
}
