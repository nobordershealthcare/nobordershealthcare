package middleware

import (
	"net/http"
	"sync/atomic"
)

// RequestCounter is the shared atomic counter incremented by the middleware
// and read by the health probe and lifecycle goroutine.
type RequestCounter struct {
	count atomic.Int64
}

// Inc increments the counter and returns the new value.
func (c *RequestCounter) Inc() int64 {
	return c.count.Add(1)
}

// Load returns the current count.
func (c *RequestCounter) Load() int64 {
	return c.count.Load()
}

// AtomicInt64 returns the underlying *atomic.Int64 for use by health/probe.go.
func (c *RequestCounter) AtomicInt64() *atomic.Int64 {
	return &c.count
}

// CountRequests increments the shared counter on every inbound request,
// including requests that are rejected by later middleware (JWT, mTLS).
// Counting before authentication prevents a slow leak where an attacker
// floods the server with unauthenticated requests that never increment the
// counter, extending the pod's lifetime indefinitely.
func CountRequests(counter *RequestCounter, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		counter.Inc()
		next.ServeHTTP(w, r)
	})
}
