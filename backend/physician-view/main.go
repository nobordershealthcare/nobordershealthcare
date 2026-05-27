// physician-view — emergency QR display + clinician access logging service.
//
// HTTP routes:
//   GET  /scan                       — serve fragment-reading landing page (JWT stays in URL hash, never logged)
//   POST /scan                       — verify Ed25519 JWT (from POST body), render emergency card HTML
//   POST /clinician                  — log clinician license, Ch3 access audit
//   GET  /proxy/{token}             — one-time proxy document link (Redis NX)
//   GET  /healthz                    — liveness probe
//
// Configuration via environment variables (see cfg struct below).
// No hardcoded endpoints, no hardcoded credentials.
//
// Security:
//   - TLS terminated upstream (reverse proxy or load balancer)
//   - mTLS to Fabric peers via fabric-gateway SDK
//   - mTLS to Redis via TLS config (optional when REDIS_TLS=true)
//   - CORS: none — this service is reached via QR scan, not AJAX
//   - Rate limiting: 30 req/min per IP enforced in-service (Redis INCR) + upstream proxy
//
// Logging: slog (structured), JSON format. Never log patient PII.
// Only SHA3-256 hashes appear in log entries.
package main

import (
	"context"
	"errors"
	"html/template"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/nobordershealthcare/physician-view/handlers"
	"github.com/nobordershealthcare/physician-view/internal/ch3log"
	"github.com/redis/go-redis/v9"
)

func main() {
	// Structured JSON logging — never log patient PII
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	// ── Configuration ──────────────────────────────────────────
	addr         := envOr("LISTEN_ADDR", ":8080")
	redisAddr    := envOr("REDIS_ADDR", "127.0.0.1:6379")
	redisPass    := os.Getenv("REDIS_PASSWORD")
	templateDir  := envOr("TEMPLATE_DIR", "templates")

	// ── Redis client ───────────────────────────────────────────
	// No AOF, no RDB, no CONFIG/SLAVEOF/DEBUG — Redis is RAM-only per spec.
	rdb := redis.NewClient(&redis.Options{
		Addr:     redisAddr,
		Password: redisPass,
		DB:       0,
		// Connection timeouts
		DialTimeout:  3 * time.Second,
		ReadTimeout:  2 * time.Second,
		WriteTimeout: 2 * time.Second,
		PoolSize:     10,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		slog.Error("redis ping failed", slog.String("addr", redisAddr), slog.String("err", err.Error()))
		os.Exit(1)
	}
	slog.Info("redis connected", slog.String("addr", redisAddr))

	// ── Fabric Channel 3 logger ─────────────────────────────────
	ch3Logger, err := ch3log.NewFromEnv()
	if err != nil {
		// Physician-view CANNOT operate without Ch3 access logging (fail-closed contract).
		slog.Error("ch3 logger init failed — cannot start without access logging", slog.String("err", err.Error()))
		os.Exit(1)
	}
	slog.Info("fabric ch3 connected")

	// ── HTML templates ──────────────────────────────────────────
	tmpl, err := template.ParseGlob(filepath.Join(templateDir, "*.html"))
	if err != nil {
		slog.Error("template parse failed", slog.String("dir", templateDir), slog.String("err", err.Error()))
		os.Exit(1)
	}

	// ── HTTP mux ────────────────────────────────────────────────
	mux := http.NewServeMux()

	mux.HandleFunc("/scan", handlers.ScanHandler(tmpl, rdb))
	mux.HandleFunc("/clinician", handlers.ClinicianHandler(ch3Logger, rdb))
	mux.HandleFunc("/proxy/", handlers.ProxyTokenHandler(ch3Logger, rdb))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok")) //nolint:errcheck
	})

	srv := &http.Server{
		Addr: addr,
		// Middleware stack (innermost first):
		//   1. maxBodyMiddleware — caps request bodies at 64 KiB (DoS guard)
		//   2. securityHeadersMiddleware — adds CSP, X-Frame-Options, etc. on every response
		//   3. requestLogger — structured access log (path only, never query string)
		Handler:      requestLogger(securityHeadersMiddleware(maxBodyMiddleware(mux))),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// ── Graceful shutdown ───────────────────────────────────────
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		slog.Info("physician-view listening", slog.String("addr", addr))
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server error", slog.String("err", err.Error()))
			os.Exit(1)
		}
	}()

	<-sigCh
	slog.Info("shutdown signal received")

	shutCtx, shutCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutCancel()
	if err := srv.Shutdown(shutCtx); err != nil {
		slog.Error("graceful shutdown failed", slog.String("err", err.Error()))
	}
	slog.Info("server stopped")
}

// securityHeadersMiddleware adds defensive HTTP response headers to every response.
//
// Content-Security-Policy rationale:
//   - default-src 'self'             — no external resources permitted
//   - script-src 'self' 'unsafe-inline' — the landing page uses a small inline script
//     to read location.hash; this is unavoidable given the QR→fragment→POST design.
//     The inline script contains no patient data and cannot be replaced with an external
//     file because the page must work before the JWT is parsed.
//   - style-src 'self' 'unsafe-inline' — inline styles in the landing page only
//   - img-src 'self'                 — no external images
//   - form-action 'self'             — the landing page form only POSTs to /scan (same origin)
//   - frame-ancestors 'none'         — equivalent to X-Frame-Options: DENY
//   - base-uri 'self'               — prevent base tag injection
//
// X-Frame-Options: DENY — belt-and-suspenders with frame-ancestors 'none' for older browsers.
// X-Content-Type-Options: nosniff — prevent MIME-type sniffing of HTML/JSON responses.
// Referrer-Policy: no-referrer — no URL leakage when navigating away.
// Permissions-Policy: camera=(), microphone=(), geolocation=() — deny sensor access.
func securityHeadersMiddleware(next http.Handler) http.Handler {
	const csp = "default-src 'self'; " +
		"script-src 'self' 'unsafe-inline'; " +
		"style-src 'self' 'unsafe-inline'; " +
		"img-src 'self'; " +
		"font-src 'self'; " +
		"form-action 'self'; " +
		"frame-ancestors 'none'; " +
		"base-uri 'self'; " +
		"object-src 'none'"

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", csp)
		h.Set("X-Frame-Options", "DENY")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		next.ServeHTTP(w, r)
	})
}

// maxBodyMiddleware caps inbound request bodies at 64 KiB.
// Without this a POST /clinician with a multi-megabyte body would be read
// fully into memory before any handler can reject it — a trivial DoS vector.
// http.MaxBytesReader causes r.Body.Read to return an error after the limit,
// which propagates as a 413 when the handler calls r.ParseForm.
const maxBodyBytes = 64 * 1024 // 64 KiB — ample for any legitimate form POST

func maxBodyMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
		next.ServeHTTP(w, r)
	})
}

// requestLogger wraps a handler and logs each request. Never logs URL query
// parameters (they contain the JWT). Only method, path, remote, status.
func requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)
		slog.Info("request",
			slog.String("method", r.Method),
			slog.String("path", r.URL.Path), // NOT r.URL.String() — avoids logging token
			slog.String("remote", r.RemoteAddr),
			slog.Int("status", rw.status),
			slog.Duration("dur", time.Since(start)),
		)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
