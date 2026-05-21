package middleware

import (
	"crypto/tls"
	"net/http"
)

// RequireMTLS rejects requests that arrive without a verified client certificate.
// It must be the first handler in the chain — placed before JWT verification —
// so that unauthenticated callers cannot reach any application logic.
//
// In production the TLS termination and mTLS enforcement happens at the Istio
// sidecar (Envoy). This middleware provides defence-in-depth: if the sidecar
// is misconfigured, the application itself rejects uncertified requests.
func RequireMTLS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil || len(r.TLS.VerifiedChains) == 0 {
			http.Error(w, "client certificate required", http.StatusUnauthorized)
			return
		}

		// Confirm the peer cert was verified against our CA (VerifiedChains
		// is non-nil only when tls.Config.ClientAuth >= RequireAndVerifyClientCert).
		state := r.TLS
		if state.HandshakeComplete && !hasVerifiedPeer(state) {
			http.Error(w, "client certificate not verified", http.StatusUnauthorized)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func hasVerifiedPeer(state *tls.ConnectionState) bool {
	return len(state.VerifiedChains) > 0 && len(state.VerifiedChains[0]) > 0
}
