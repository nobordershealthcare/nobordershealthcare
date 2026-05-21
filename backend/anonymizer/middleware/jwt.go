package middleware

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

type contextKey string

const claimsKey contextKey = "jwt_claims"

// Claims is the minimal set extracted from a verified JWT.
type Claims struct {
	Subject string // SHA3-256(userID) — never the raw user identifier
	Role    string
	Scope   []string
	JTI     string // JWT ID for replay prevention (handled by gatekeeper)
	Exp     int64  // Unix timestamp
}

// VerifyJWT validates an Ed25519-signed JWT from the Authorization header.
// Rejects tokens with TTL > 15 minutes (CLAUDE.md hard limit).
// Verified claims are stored in the request context for downstream handlers.
//
// Key distribution: the Ed25519 public key is provided at construction time,
// loaded from Vault (never hardcoded). Rotation requires a pod restart or
// a fsnotify-triggered swap in vault.go.
func VerifyJWT(pubKey ed25519.PublicKey, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, err := extractBearerToken(r)
		if err != nil {
			http.Error(w, "missing or malformed Authorization header", http.StatusUnauthorized)
			return
		}

		claims, err := parseAndVerify(raw, pubKey)
		if err != nil {
			// Log only the error type, not the token content.
			slog.Warn("jwt verification failed", "err", err, "remote_addr", r.RemoteAddr)
			http.Error(w, "invalid token", http.StatusUnauthorized)
			return
		}

		ctx := context.WithValue(r.Context(), claimsKey, claims)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// ClaimsFromContext retrieves verified JWT claims from the request context.
// Returns nil if the JWT middleware was not in the handler chain.
func ClaimsFromContext(ctx context.Context) *Claims {
	v, _ := ctx.Value(claimsKey).(*Claims)
	return v
}

func parseAndVerify(raw string, pubKey ed25519.PublicKey) (*Claims, error) {
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("malformed jwt")
	}

	// Verify signature over header.payload.
	signingInput := parts[0] + "." + parts[1]
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, fmt.Errorf("decode signature: %w", err)
	}
	if !ed25519.Verify(pubKey, []byte(signingInput), sig) {
		return nil, fmt.Errorf("signature invalid")
	}

	// Decode payload.
	payloadJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("decode payload: %w", err)
	}
	var raw2 struct {
		Sub   string   `json:"sub"`
		Role  string   `json:"role"`
		Scope []string `json:"scope"`
		JTI   string   `json:"jti"`
		Exp   int64    `json:"exp"`
		Iat   int64    `json:"iat"`
	}
	if err := json.Unmarshal(payloadJSON, &raw2); err != nil {
		return nil, fmt.Errorf("unmarshal claims: %w", err)
	}

	now := time.Now().Unix()

	// Hard expiry check.
	if raw2.Exp <= now {
		return nil, fmt.Errorf("token expired")
	}

	// Enforce 15-minute maximum TTL (CLAUDE.md: "JWT TTL: 15 minutes max").
	maxTTL := int64(15 * 60)
	if raw2.Exp-raw2.Iat > maxTTL {
		return nil, fmt.Errorf("token TTL exceeds 15-minute maximum")
	}

	// sub must be a 64-char lowercase hex string (SHA3-256 of userID).
	if len(raw2.Sub) != 64 {
		return nil, fmt.Errorf("sub must be 64-char hash")
	}

	return &Claims{
		Subject: raw2.Sub,
		Role:    raw2.Role,
		Scope:   raw2.Scope,
		JTI:     raw2.JTI,
		Exp:     raw2.Exp,
	}, nil
}

func extractBearerToken(r *http.Request) (string, error) {
	auth := r.Header.Get("Authorization")
	if auth == "" {
		return "", fmt.Errorf("missing Authorization header")
	}
	if !strings.HasPrefix(auth, "Bearer ") {
		return "", fmt.Errorf("not a Bearer token")
	}
	tok := strings.TrimPrefix(auth, "Bearer ")
	if tok == "" {
		return "", fmt.Errorf("empty token")
	}
	return tok, nil
}
