// Package health provides k8s liveness and readiness probes for the
// normalization service.
package health

import (
	"encoding/json"
	"net/http"

	"github.com/gocql/gocql"
)

// status is the JSON body returned by both probe endpoints.
type status struct {
	Status string            `json:"status"`
	Checks map[string]string `json:"checks"`
}

// Handler returns an http.ServeMux with /healthz (liveness) and /readyz (readiness).
func Handler(session *gocql.Session) http.Handler {
	mux := http.NewServeMux()

	// /healthz — liveness: is the process alive?
	// Always returns 200 if the HTTP server is running.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, status{
			Status: "ok",
			Checks: map[string]string{"process": "alive"},
		})
	})

	// /readyz — readiness: are dependencies reachable?
	// k8s stops routing traffic to the pod if this returns non-200.
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		checks := map[string]string{}
		allOK := true

		// Check ScyllaDB connectivity.
		if err := session.Query("SELECT now() FROM system.local").Exec(); err != nil {
			checks["scylladb"] = "error: " + err.Error()
			allOK = false
		} else {
			checks["scylladb"] = "ok"
		}

		st := "ok"
		code := http.StatusOK
		if !allOK {
			st = "degraded"
			code = http.StatusServiceUnavailable
		}
		writeJSON(w, code, status{Status: st, Checks: checks})
	})

	return mux
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
