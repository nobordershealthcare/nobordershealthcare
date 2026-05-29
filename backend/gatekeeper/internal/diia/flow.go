package diia

// flow.go — Diia v2 end-to-end HTTP handlers.
//
// Four endpoints:
//   POST /diia/sign          → deeplink for hashedFilesSigning (Scenario 1)
//   POST /diia/auth          → deeplink for DiiaID auth        (Scenario 2)
//   POST /diia/callback      → receive encodeData from Diia app
//   GET  /diia/status/:id    → one-time poll; deletes result after read
//
// Callback format (multipart/mixed or application/json per Diia version):
//   Header X-Document-Request-Trace-Id: {requestId}
//   Header X-Diia-Id-Action: hashedFilesSigning | auth
//   Field  encodeData: base64-encoded JSON payload
//
// The raw encodeData is stored as-is for the iOS client to decode and
// verify locally (no server-side CAdES-BES verification in this flow).
// Server-side CAdES-BES verification is handled by HandleSignCallback
// (the v1 flow in callback.go).
//
// Redis key schema:
//   diia:flow:request:{requestId}  → FlowRequest (TTL 10 min)
//   diia:flow:result:{requestId}   → FlowResult  (TTL 10 min, deleted on first read)

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"mime"
	"mime/multipart"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// ── FlowStore ────────────────────────────────────────────────────────────

// FlowStore is the Redis interface used by the v2 flow handlers.
// *Store satisfies this interface; tests inject a mock.
type FlowStore interface {
	SaveFlowRequest(ctx context.Context, req FlowRequest) error
	GetFlowRequest(ctx context.Context, requestID string) (*FlowRequest, error)
	SaveFlowResult(ctx context.Context, res FlowResult) error
	// GetAndDeleteFlowResult atomically reads and deletes the result (one-time).
	GetAndDeleteFlowResult(ctx context.Context, requestID string) (*FlowResult, error)
}

// ── FlowRequest / FlowResult (defined in store.go) ───────────────────────
// (types defined below, methods in store.go)

// ── POST /diia/sign ───────────────────────────────────────────────────────

// DiiaSignRequest is the JSON body accepted by HandleDiiaSign.
type DiiaSignRequest struct {
	FileName   string `json:"file_name"`
	FileHash   string `json:"file_hash"`   // base64 SHA-256 (use HashFileBase64)
	FileSize   int64  `json:"file_size,omitempty"`
	FileKey    string `json:"file_key,omitempty"`   // caller-assigned; uuid if empty
	ReturnLink string `json:"return_link,omitempty"`
}

// HandleDiiaSign starts a hashedFilesSigning session.
// Generates a UUID requestId, stores it in Redis, calls Diia v2 dynamic
// offer-request, returns {deeplink, request_id}.
func HandleDiiaSign(client ClientInterface, ids *IDCache, store FlowStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx := r.Context()
		r.Body = http.MaxBytesReader(w, r.Body, 64*1024)

		var req DiiaSignRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		if req.FileName == "" || req.FileHash == "" {
			http.Error(w, "file_name and file_hash are required", http.StatusBadRequest)
			return
		}

		requestID := uuid.New().String()
		fileKey := req.FileKey
		if fileKey == "" {
			fileKey = uuid.New().String()
		}

		if err := store.SaveFlowRequest(ctx, FlowRequest{
			RequestID: requestID,
			Action:    "hashedFilesSigning",
			CreatedAt: time.Now().UTC(),
		}); err != nil {
			slog.Error("diia sign: SaveFlowRequest failed",
				slog.String("request_id", requestID), slog.String("err", err.Error()))
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		deeplink, err := client.GetSigningDeeplink(ctx, ids.BranchID, ids.SigningOfferID, requestID,
			[]HashedFile{{
				FileName: req.FileName,
				FileSize: req.FileSize,
				FileHash: req.FileHash,
				FileKey:  fileKey,
			}})
		if err != nil {
			slog.Error("diia sign: GetSigningDeeplink failed",
				slog.String("request_id", requestID), slog.String("err", err.Error()))
			http.Error(w, "diia unavailable", http.StatusServiceUnavailable)
			return
		}

		slog.Info("diia sign: session created", slog.String("request_id", requestID))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{ //nolint:errcheck
			"deeplink":   deeplink,
			"request_id": requestID,
		})
	}
}

// ── POST /diia/auth ───────────────────────────────────────────────────────

// DiiaAuthFlowRequest is the JSON body accepted by HandleDiiaAuth.
type DiiaAuthFlowRequest struct {
	ReturnLink string `json:"return_link,omitempty"`
}

// HandleDiiaAuth starts a DiiaID identity-verification session.
// requestId is base64(SHA-256(uuid)) — the format Diia requires for auth.
func HandleDiiaAuth(client ClientInterface, ids *IDCache, store FlowStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx := r.Context()
		r.Body = http.MaxBytesReader(w, r.Body, 4*1024)

		// requestId = base64(SHA-256(uuid)) — 44 chars, required by Diia auth spec
		requestID, _ := AuthRequestID()

		if err := store.SaveFlowRequest(ctx, FlowRequest{
			RequestID: requestID,
			Action:    "auth",
			CreatedAt: time.Now().UTC(),
		}); err != nil {
			slog.Error("diia auth flow: SaveFlowRequest failed",
				slog.String("err", err.Error()))
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		deeplink, err := client.GetAuthDeeplink(ctx, ids.BranchID, ids.AuthOfferID, requestID)
		if err != nil {
			slog.Error("diia auth flow: GetAuthDeeplink failed",
				slog.String("err", err.Error()))
			http.Error(w, "diia unavailable", http.StatusServiceUnavailable)
			return
		}

		slog.Info("diia auth flow: session created", slog.String("request_id", requestID))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{ //nolint:errcheck
			"deeplink":   deeplink,
			"request_id": requestID,
		})
	}
}

// ── POST /diia/callback ───────────────────────────────────────────────────

// HandleDiiaCallback receives the signed/auth data from the Diia app.
//
// Diia sends either:
//   - multipart/mixed with an "encodeData" field (base64-encoded JSON)
//   - application/json with an "encodeData" key directly
//
// The raw encodeData is stored in Redis for the iOS client to poll via
// /diia/status/{requestId} and process locally.
//
// Anti-replay: requestId must exist in Redis (TTL 10 min from /diia/sign or
// /diia/auth). Unknown requestIds receive 200 to stop Diia retries.
func HandleDiiaCallback(store FlowStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ctx := r.Context()
		r.Body = http.MaxBytesReader(w, r.Body, 8<<20) // 8 MiB

		// Diia sends requestId and action in headers.
		requestID := r.Header.Get("X-Document-Request-Trace-Id")
		action := r.Header.Get("X-Diia-Id-Action")

		if requestID == "" {
			slog.Warn("diia callback: missing X-Document-Request-Trace-Id")
			http.Error(w, "missing request trace id", http.StatusBadRequest)
			return
		}

		// Anti-replay: requestId must have been issued by us.
		req, err := store.GetFlowRequest(ctx, requestID)
		if err != nil {
			slog.Error("diia callback: GetFlowRequest failed",
				slog.String("request_id", requestID), slog.String("err", err.Error()))
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if req == nil {
			slog.Warn("diia callback: unknown or expired requestId",
				slog.String("request_id", requestID))
			// 200 halts Diia retries for unknown IDs.
			w.WriteHeader(http.StatusOK)
			return
		}
		if action == "" {
			action = req.Action // fall back to stored action if header absent
		}

		// Extract encodeData from body (multipart or JSON).
		encodeData, err := extractEncodeData(r)
		if err != nil {
			slog.Warn("diia callback: extract encodeData failed",
				slog.String("request_id", requestID), slog.String("err", err.Error()))
			http.Error(w, "cannot extract encodeData", http.StatusBadRequest)
			return
		}

		if err := store.SaveFlowResult(ctx, FlowResult{
			RequestID:  requestID,
			Action:     action,
			EncodeData: encodeData,
			ReceivedAt: time.Now().UTC(),
		}); err != nil {
			slog.Error("diia callback: SaveFlowResult failed",
				slog.String("request_id", requestID), slog.String("err", err.Error()))
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		slog.Info("diia callback: result stored",
			slog.String("request_id", requestID),
			slog.String("action", action),
		)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]bool{"success": true}) //nolint:errcheck
	}
}

// extractEncodeData parses the Diia callback body and returns the raw
// base64 encodeData string. Handles both multipart/mixed and JSON bodies.
func extractEncodeData(r *http.Request) (string, error) {
	ct := r.Header.Get("Content-Type")
	mediaType, params, _ := mime.ParseMediaType(ct)

	if strings.HasPrefix(mediaType, "multipart/") {
		mr := multipart.NewReader(r.Body, params["boundary"])
		for {
			part, err := mr.NextPart()
			if err == io.EOF {
				break
			}
			if err != nil {
				return "", err
			}
			if part.FormName() == "encodeData" {
				data, err := io.ReadAll(io.LimitReader(part, 4<<20))
				part.Close()
				if err != nil {
					return "", err
				}
				return strings.TrimSpace(string(data)), nil
			}
			part.Close()
		}
		return "", nil // encodeData field absent (e.g. processing notification)
	}

	// JSON body fallback
	var payload struct {
		EncodeData string `json:"encodeData"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		return "", err
	}
	return payload.EncodeData, nil
}

// ── GET /diia/status/{requestId} ─────────────────────────────────────────

// DiiaStatusResponse is the JSON body returned by HandleDiiaStatus.
type DiiaStatusResponse struct {
	Status     string `json:"status"`
	EncodeData string `json:"encode_data,omitempty"`
	Action     string `json:"action,omitempty"`
}

// HandleDiiaStatus polls for a Diia callback result.
//
// On success the result is deleted from Redis — one-time read.
// iOS polls every 2 s; maximum 90 iterations (3-minute window).
//
// Status values:
//   pending  — no callback received yet
//   complete — encodeData available (then deleted)
//   expired  — requestId TTL elapsed or never seen
func HandleDiiaStatus(store FlowStore) http.HandlerFunc {
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

		ctx := r.Context()
		w.Header().Set("Content-Type", "application/json")

		// Is the session still live?
		req, err := store.GetFlowRequest(ctx, requestID)
		if err != nil {
			slog.Error("diia status: GetFlowRequest failed",
				slog.String("request_id", requestID), slog.String("err", err.Error()))
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if req == nil {
			json.NewEncoder(w).Encode(DiiaStatusResponse{Status: "expired"}) //nolint:errcheck
			return
		}

		// Try to atomically read+delete the result.
		result, err := store.GetAndDeleteFlowResult(ctx, requestID)
		if err != nil {
			slog.Error("diia status: GetAndDeleteFlowResult failed",
				slog.String("request_id", requestID), slog.String("err", err.Error()))
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if result == nil {
			json.NewEncoder(w).Encode(DiiaStatusResponse{Status: "pending"}) //nolint:errcheck
			return
		}

		slog.Info("diia status: result delivered (one-time)",
			slog.String("request_id", requestID),
			slog.String("action", result.Action),
		)
		json.NewEncoder(w).Encode(DiiaStatusResponse{ //nolint:errcheck
			Status:     "complete",
			EncodeData: result.EncodeData,
			Action:     result.Action,
		})
	}
}

// ── FlowRequest / FlowResult types ───────────────────────────────────────

// FlowRequest is stored when /diia/sign or /diia/auth creates a session.
type FlowRequest struct {
	RequestID string    `json:"request_id"`
	Action    string    `json:"action"` // "hashedFilesSigning" | "auth"
	CreatedAt time.Time `json:"created_at"`
}

// FlowResult is stored when /diia/callback receives encodeData from Diia.
// It is deleted from Redis after the first successful /diia/status read.
type FlowResult struct {
	RequestID  string    `json:"request_id"`
	Action     string    `json:"action"`
	EncodeData string    `json:"encode_data"` // raw base64 from Diia — NOT logged
	ReceivedAt time.Time `json:"received_at"`
}

// Compile-time check: redis.Nil sentinel used in store.go
var _ = redis.Nil
