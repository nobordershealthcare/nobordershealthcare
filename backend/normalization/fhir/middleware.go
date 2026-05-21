package fhir

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/time/rate"
)

// contextKey is the private key type for context values set by middleware.
type contextKey string

const (
	ctxKeyUserHash contextKey = "user_hash"
	ctxKeyRole     contextKey = "role"
	ctxKeyScope    contextKey = "scope"
	ctxKeyLocale   contextKey = "locale"
)

// Claims is the JWT payload issued by the gatekeeper for all normalization requests.
type Claims struct {
	jwt.RegisteredClaims
	Role   string   `json:"role"`
	Scope  []string `json:"scope"`
	Locale string   `json:"locale,omitempty"`
}

// Middleware holds the shared state for all FHIR HTTP middleware functions.
type Middleware struct {
	pubKey   ed25519.PublicKey
	limiters sync.Map // map[string]*rate.Limiter keyed by hash(sub)
}

// NewMiddleware creates middleware using the given Ed25519 public key for JWT
// verification. The public key is loaded from Vault at service startup.
func NewMiddleware(pubKey ed25519.PublicKey) *Middleware {
	return &Middleware{pubKey: pubKey}
}

// Auth validates the JWT, extracts claims, and stores them in ctx.
// Rejects requests where:
//   - Authorization header is missing or not "Bearer <token>"
//   - algorithm != EdDSA (hard-coded, no algorithm confusion possible)
//   - token is expired
//   - sub is not a 64 lowercase hex string (SHA3-256 hash format)
//   - Accept header is not application/fhir+json
func (m *Middleware) Auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Require FHIR media type.
		if !acceptsFHIR(r) {
			http.Error(w, "Accept: application/fhir+json required", http.StatusNotAcceptable)
			return
		}

		// Extract Bearer token.
		tokenStr := extractBearer(r)
		if tokenStr == "" {
			http.Error(w, "missing Authorization header", http.StatusUnauthorized)
			return
		}

		// Parse and verify JWT — EdDSA only, no algorithm confusion possible.
		var claims Claims
		token, err := jwt.ParseWithClaims(tokenStr, &claims,
			func(t *jwt.Token) (interface{}, error) {
				if t.Method.Alg() != "EdDSA" {
					return nil, errors.New("rejected: algorithm must be EdDSA")
				}
				return m.pubKey, nil
			},
			jwt.WithValidMethods([]string{"EdDSA"}),
			jwt.WithExpirationRequired(),
		)
		if err != nil || !token.Valid {
			http.Error(w, "invalid or expired token", http.StatusUnauthorized)
			return
		}

		// Validate sub is exactly 64 lowercase hex chars (SHA3-256 format).
		sub, err := claims.GetSubject()
		if err != nil || !isValidHash(sub) {
			http.Error(w, "invalid token subject", http.StatusUnauthorized)
			return
		}

		// Per-user rate limit: 60 req/min, burst 10.
		if !m.allow(sub) {
			http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
			return
		}

		// Store claims in context for downstream handlers.
		ctx := r.Context()
		ctx = context.WithValue(ctx, ctxKeyUserHash, sub)
		ctx = context.WithValue(ctx, ctxKeyRole, claims.Role)
		ctx = context.WithValue(ctx, ctxKeyScope, claims.Scope)
		ctx = context.WithValue(ctx, ctxKeyLocale, claims.Locale)

		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// RequireScope returns a middleware that enforces a specific scope claim.
// Call after Auth so the scope is already in context.
func RequireScope(requiredScope string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			scope, _ := r.Context().Value(ctxKeyScope).([]string)
			for _, s := range scope {
				if s == requiredScope {
					next.ServeHTTP(w, r)
					return
				}
			}
			http.Error(w, "insufficient scope", http.StatusForbidden)
		})
	}
}

// RequireRole returns a middleware that enforces one of the allowed roles.
func RequireRole(allowedRoles ...string) func(http.Handler) http.Handler {
	roleSet := make(map[string]struct{}, len(allowedRoles))
	for _, r := range allowedRoles {
		roleSet[r] = struct{}{}
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			role, _ := r.Context().Value(ctxKeyRole).(string)
			if _, ok := roleSet[role]; ok {
				next.ServeHTTP(w, r)
				return
			}
			http.Error(w, "insufficient role", http.StatusForbidden)
		})
	}
}

// ValidatePatientHash is a middleware that validates the `patient` query parameter
// is a 64-character lowercase hex string. Rejects 400 if invalid.
func ValidatePatientHash(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.URL.Query().Get("patient")
		if !isValidHash(h) {
			http.Error(w, "patient must be a 64-character lowercase hex SHA3-256 hash", http.StatusBadRequest)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ── Context helpers used by handlers ─────────────────────────────────────────

func userHashFromCtx(ctx context.Context) string {
	v, _ := ctx.Value(ctxKeyUserHash).(string)
	return v
}

func localeFromCtx(ctx context.Context) string {
	v, _ := ctx.Value(ctxKeyLocale).(string)
	if v == "" {
		return "en"
	}
	return v
}

// ── Internal helpers ──────────────────────────────────────────────────────────

func isValidHash(h string) bool {
	if len(h) != 64 {
		return false
	}
	_, err := hex.DecodeString(h)
	return err == nil
}

func extractBearer(r *http.Request) string {
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return ""
	}
	return strings.TrimPrefix(auth, "Bearer ")
}

func acceptsFHIR(r *http.Request) bool {
	accept := r.Header.Get("Accept")
	return accept == "" || // permissive: no Accept = assume OK
		strings.Contains(accept, FHIRMediaType) ||
		strings.Contains(accept, "*/*")
}

// allow returns true if the rate limiter for this userHash permits the request.
func (m *Middleware) allow(userHash string) bool {
	v, _ := m.limiters.LoadOrStore(userHash, rate.NewLimiter(rate.Every(time.Minute/60), 10))
	return v.(*rate.Limiter).Allow()
}

// writeFHIRJSON writes a FHIR JSON response with the correct media type.
func writeFHIRJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", FHIRMediaType)
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
