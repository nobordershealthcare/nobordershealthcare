package health

import (
	"net/http"
	"sync/atomic"
	"time"
)

// Probe implements k8s liveness (/healthz/live) and readiness (/healthz/ready)
// endpoints. Readiness goes 503 when the pod should stop receiving traffic —
// either the request counter has reached its maximum or the pod age has
// exceeded 1 hour. The liveness probe stays 200 throughout to prevent
// spurious pod restarts during graceful drain.
type Probe struct {
	requestCount *atomic.Int64
	maxRequests  int64
	startTime    time.Time
	maxAge       time.Duration
}

func NewProbe(requestCount *atomic.Int64, maxRequests int64) *Probe {
	return &Probe{
		requestCount: requestCount,
		maxRequests:  maxRequests,
		startTime:    time.Now(),
		maxAge:       1 * time.Hour,
	}
}

// Live always returns 200 while the process is running.
// k8s only restarts the pod if this returns non-2xx.
func (p *Probe) Live(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
}

// Ready returns 503 when either shutdown threshold is crossed.
// k8s stops routing new traffic to this pod as soon as it sees 503 here.
// In-flight requests continue to drain until the grace period expires.
func (p *Probe) Ready(w http.ResponseWriter, r *http.Request) {
	if p.shouldShutdown() {
		http.Error(w, "draining", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// ShouldShutdown returns true if either shutdown threshold is crossed.
// Called by main.go's lifecycle goroutine to trigger graceful shutdown.
func (p *Probe) ShouldShutdown() bool {
	return p.shouldShutdown()
}

func (p *Probe) shouldShutdown() bool {
	if p.requestCount.Load() >= p.maxRequests {
		return true
	}
	if time.Since(p.startTime) >= p.maxAge {
		return true
	}
	return false
}

// RegisterRoutes attaches the probe endpoints to the given mux.
func (p *Probe) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/healthz/live", p.Live)
	mux.HandleFunc("/healthz/ready", p.Ready)
}
