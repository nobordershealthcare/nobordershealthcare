package auth

import (
	"context"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

const (
	jtiKeyPrefix = "jti:"
	jwtMaxAge    = 15 * time.Minute
)

// Claims is the set of fields present in every gatekeeper-issued JWT.
// The sub field is always SHA3-256(salt+userID) — never plaintext.
type Claims struct {
	Role  string   `json:"role"`
	Scope []string `json:"scope"`
	jwt.RegisteredClaims
}

// JWTService issues and verifies EdDSA-signed JWTs with jti replay protection.
type JWTService struct {
	privKey ed25519.PrivateKey
	pubKey  ed25519.PublicKey
	redis   *redis.Client
}

func NewJWTService(privKeyPath, pubKeyPath string, redisClient *redis.Client) (*JWTService, error) {
	priv, pub, err := loadEd25519KeyPair(privKeyPath, pubKeyPath)
	if err != nil {
		return nil, fmt.Errorf("load jwt keys: %w", err)
	}
	return &JWTService{
		privKey: priv,
		pubKey:  pub,
		redis:   redisClient,
	}, nil
}

// Issue creates a signed JWT for the given hashed subject. hashedUserID must be
// a 64-char lowercase hex string (SHA3-256 output) — it is not validated here
// because AuthenticateAndHash already enforces the invariant.
func (s *JWTService) Issue(ctx context.Context, hashedUserID, role string, scope []string) (string, error) {
	now := time.Now().UTC()
	exp := now.Add(jwtMaxAge)
	jti := uuid.New().String()

	claims := Claims{
		Role:  role,
		Scope: scope,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   hashedUserID,
			Issuer:    "nobordershealthcare/gatekeeper", // H-01: required for issuer validation on Verify
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(exp),
			ID:        jti,
		},
	}

	// jwt.SigningMethodEdDSA hardcodes alg=EdDSA in the header.
	token := jwt.NewWithClaims(jwt.SigningMethodEdDSA, claims)
	signed, err := token.SignedString(s.privKey)
	if err != nil {
		return "", fmt.Errorf("sign jwt: %w", err)
	}
	return signed, nil
}

// Verify parses and validates a JWT. Returns the claims on success.
//
// Security properties enforced:
//  1. Algorithm pinning: WithValidMethods rejects any alg other than EdDSA
//     before the library touches the signature — prevents alg:none and RS256 confusion.
//  2. jti replay: each jti is recorded in Redis with TTL = remaining token lifetime.
//     A second request with the same jti within the validity window returns ErrReplay.
//  3. Expiry: standard exp claim checked by the library; additionally we verify the
//     window does not exceed jwtMaxAge to guard against tokens issued with long exp.
func (s *JWTService) Verify(ctx context.Context, tokenStr string) (*Claims, error) {
	var claims Claims

	token, err := jwt.ParseWithClaims(
		tokenStr,
		&claims,
		func(t *jwt.Token) (any, error) {
			// Keyfunc is only reached when alg passes the WithValidMethods check.
			return s.pubKey, nil
		},
		// CRITICAL: this option makes the library check header.alg against the
		// allowlist before calling Keyfunc or verifying the signature.
		// alg:none, RS256, HS256, or any other algorithm will return an error here.
		jwt.WithValidMethods([]string{"EdDSA"}),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithStrictDecoding(),
		// H-01: Validate issuer claim — rejects tokens issued by any other service
		// (e.g., an attacker who obtained a signing key for a different service).
		jwt.WithIssuer("nobordershealthcare/gatekeeper"),
	)
	if err != nil {
		return nil, fmt.Errorf("jwt parse: %w", err)
	}
	if !token.Valid {
		return nil, errors.New("jwt invalid")
	}

	// Enforce our own max-age ceiling regardless of what exp says.
	if claims.ExpiresAt == nil || claims.IssuedAt == nil {
		return nil, errors.New("jwt missing time claims")
	}
	window := claims.ExpiresAt.Time.Sub(claims.IssuedAt.Time)
	if window > jwtMaxAge {
		return nil, fmt.Errorf("jwt validity window %v exceeds maximum %v", window, jwtMaxAge)
	}

	// jti replay protection: SETNX with TTL = remaining lifetime.
	if err := s.checkAndRecordJTI(ctx, claims.ID, claims.ExpiresAt.Time); err != nil {
		return nil, err
	}

	return &claims, nil
}

// ErrReplay is returned when the jti has already been seen within its validity window.
var ErrReplay = errors.New("jwt replay detected")

func (s *JWTService) checkAndRecordJTI(ctx context.Context, jti string, exp time.Time) error {
	if jti == "" {
		return errors.New("jwt missing jti")
	}

	key := jtiKeyPrefix + jti
	ttl := time.Until(exp)
	if ttl <= 0 {
		// Already expired — the library should have caught this, but be defensive.
		return errors.New("jwt expired")
	}

	// SetNX returns true if the key was newly set (first use), false if it already existed.
	set, err := s.redis.SetNX(ctx, key, "1", ttl).Result()
	if err != nil {
		// Redis failure → fail closed. A replay check we can't perform is not safe to skip.
		return fmt.Errorf("jti replay check failed: %w", err)
	}
	if !set {
		return ErrReplay
	}
	return nil
}

func loadEd25519KeyPair(privPath, pubPath string) (ed25519.PrivateKey, ed25519.PublicKey, error) {
	privPEM, err := os.ReadFile(privPath)
	if err != nil {
		return nil, nil, fmt.Errorf("read priv key: %w", err)
	}
	block, _ := pem.Decode(privPEM)
	if block == nil {
		return nil, nil, errors.New("priv key: no PEM block")
	}
	privRaw, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, nil, fmt.Errorf("parse priv key: %w", err)
	}
	priv, ok := privRaw.(ed25519.PrivateKey)
	if !ok {
		return nil, nil, errors.New("priv key is not Ed25519")
	}

	pubPEM, err := os.ReadFile(pubPath)
	if err != nil {
		return nil, nil, fmt.Errorf("read pub key: %w", err)
	}
	block, _ = pem.Decode(pubPEM)
	if block == nil {
		return nil, nil, errors.New("pub key: no PEM block")
	}
	pubRaw, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, nil, fmt.Errorf("parse pub key: %w", err)
	}
	pub, ok := pubRaw.(ed25519.PublicKey)
	if !ok {
		return nil, nil, errors.New("pub key is not Ed25519")
	}

	return priv, pub, nil
}
