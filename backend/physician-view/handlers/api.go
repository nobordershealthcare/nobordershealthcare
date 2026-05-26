// api.go — GET /api/card
//
// JSON API consumed by the HTML5 web frontend (app.js).
// Verifies the patient JWT and returns the card payload as JSON.
// No HTML rendering — that lives entirely in web/.
//
// The frontend calls this AFTER the clinician has submitted their licence via
// POST /clinician. There is no server-side gate on this endpoint beyond JWT
// validity and consent revocation — the UI gate is enforced in app.js.
//
// Rate-limiting and revocation checks are shared with ScanHandler via the
// same Redis helpers.
//
// CORS: not needed — same origin as the web app. No cross-origin clients.
// Cache: no-store on all responses (patient data).
package handlers

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/nobordershealthcare/physician-view/internal/jwtverify"
	"github.com/redis/go-redis/v9"
)

// CardAPIResponse is the JSON payload returned by GET /api/card.
// All fields are safe to transmit: sub_ref is a 16-char truncation of
// SHA3-256(salt+userID) — not re-identifiable. No raw JWT is echoed back.
type CardAPIResponse struct {
	Verified    bool                       `json:"verified"`
	Exp         string                     `json:"exp"`      // human-readable UTC string
	ExpUnix     int64                      `json:"exp_unix"` // for JS countdown timer
	SubRef      string                     `json:"sub_ref"`  // 16-char SHA3-256 prefix
	JTI         string                     `json:"jti"`
	Lang        string                     `json:"lang"`
	Profile     string                     `json:"profile"`
	Name        string                     `json:"name"`
	DOB         string                     `json:"dob"`
	Blood       string                     `json:"blood"`
	Allergies   []string                   `json:"allergies"`
	Medications []map[string]string        `json:"medications"`
	NOK         *jwtverify.NOKInfo         `json:"nok,omitempty"`
	CBRN        *jwtverify.CBRNInfo        `json:"cbrn,omitempty"`
}

// CardAPIHandler handles GET /api/card?token=<jwt>.
// Returns CardAPIResponse JSON on success; JSON error object on failure.
func CardAPIHandler(rdb *redis.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			jsonErr(w, "method_not_allowed", http.StatusMethodNotAllowed)
			return
		}

		// Rate limit: shared with /scan, 30 req/min per IP.
		if !scanRateAllow(r.Context(), rdb, r.RemoteAddr) {
			jsonErr(w, "rate_limited", http.StatusTooManyRequests)
			return
		}

		tokenStr := strings.TrimSpace(r.URL.Query().Get("token"))
		if tokenStr == "" {
			jsonErr(w, "missing_token", http.StatusBadRequest)
			return
		}

		claims, err := jwtverify.Verify(tokenStr)
		if err != nil {
			code := http.StatusUnauthorized
			if errors.Is(err, jwtverify.ErrExpired) {
				code = http.StatusGone
			}
			// Never log the token — it contains patient data.
			slog.Warn("api/card jwt verify failed",
				slog.String("err", err.Error()),
				slog.String("remote", r.RemoteAddr),
			)
			jsonErr(w, errCodeFromVerifyErr(err), code)
			return
		}

		// Consent revocation check (same as ScanHandler).
		revKey := RevocationKeyPrefix + claims.Sub
		if revoked, redisErr := rdb.Exists(r.Context(), revKey).Result(); redisErr == nil && revoked > 0 {
			slog.Warn("api/card blocked — consent revoked",
				slog.String("ref", safeRef(claims.Sub)))
			jsonErr(w, "revoked", http.StatusForbidden)
			return
		}
		// Redis error: fail open (never block emergency care over cache hiccup).

		profile := claims.Profile
		if profile == "" {
			profile = "civilian"
		}

		allergies := claims.Allergies
		if allergies == nil {
			allergies = []string{}
		}
		meds := claims.Medications
		if meds == nil {
			meds = []map[string]string{}
		}

		resp := CardAPIResponse{
			Verified:    true,
			Exp:         formatUnix(claims.EXP),
			ExpUnix:     claims.EXP,
			SubRef:      safeRef(claims.Sub),
			JTI:         claims.JTI,
			Lang:        selectLanguage(claims.Lang, r.Header.Get("Accept-Language")),
			Profile:     profile,
			Name:        claims.Name,
			DOB:         claims.DOB,
			Blood:       claims.Blood,
			Allergies:   allergies,
			Medications: meds,
			NOK:         claims.NOK,
			CBRN:        claims.CBRN,
		}

		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store, no-cache")
		w.Header().Set("X-Content-Type-Options", "nosniff")

		if err := json.NewEncoder(w).Encode(resp); err != nil {
			slog.Error("api/card json encode failed", slog.String("err", err.Error()))
		}
	}
}

// errCodeFromVerifyErr maps jwtverify errors to short error code strings
// returned in the JSON error body. These are consumed by app.js.
func errCodeFromVerifyErr(err error) string {
	switch {
	case errors.Is(err, jwtverify.ErrExpired):
		return "expired"
	case errors.Is(err, jwtverify.ErrSignature):
		return "invalid_signature"
	case errors.Is(err, jwtverify.ErrAlgorithm):
		return "invalid_algorithm"
	case errors.Is(err, jwtverify.ErrMissingClaim):
		return "missing_claim"
	default:
		return "invalid"
	}
}

// jsonErr writes a JSON error object {"error": code} with the given HTTP status.
// Never echoes user input — code is a controlled constant.
func jsonErr(w http.ResponseWriter, code string, status int) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	// Ignore encode error — response already committed.
	json.NewEncoder(w).Encode(map[string]string{"error": code}) //nolint:errcheck
}
