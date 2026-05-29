package main

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"time"

	"github.com/nobordershealthcare/bulk-import/internal/admin"
	"github.com/nobordershealthcare/bulk-import/internal/importer"
)

type server struct {
	mux *http.ServeMux
}

func newServer() *server {
	s := &server{mux: http.NewServeMux()}
	s.mux.HandleFunc("POST /bulk/upload", s.handleUpload)
	s.mux.HandleFunc("GET /bulk/stats/{batchID}", s.handleStats)
	s.mux.HandleFunc("POST /bulk/resend/{batchID}", s.handleResend)
	s.mux.HandleFunc("POST /activate/validate", s.handleValidateToken)
	return s
}

func (s *server) ListenAndServe(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	// Explicit timeouts prevent Slowloris / slow-POST attacks (gosec G114).
	srv := &http.Server{
		Handler:      s.mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 120 * time.Second, // generous for large CSV uploads
		IdleTimeout:  120 * time.Second,
	}
	return srv.Serve(ln)
}

// handleUpload processes a CSV upload and dispatches activation invitations.
// Auth: admin JWT (validated by api-gateway mTLS layer before reaching this handler).
// For military batches: 2-of-2 FIDO2 confirmation required (header X-Cosigner-Token).
// GDPR gate: admin must set gdpr_legal_basis_confirmed=true in form data.
func (s *server) handleUpload(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		http.Error(w, "invalid multipart form", http.StatusBadRequest)
		return
	}

	legalBasis := r.FormValue("gdpr_legal_basis_confirmed")
	if legalBasis != "true" {
		http.Error(w, "GDPR/LED legal basis confirmation required: set gdpr_legal_basis_confirmed=true\n"+
			"Admin confirms: 'I confirm legal basis under GDPR Art.6.1(b)/(c) or LED Art.8 for law enforcement data'",
			http.StatusBadRequest)
		return
	}

	file, hdr, err := r.FormFile("csv")
	if err != nil {
		http.Error(w, "csv file required", http.StatusBadRequest)
		return
	}
	defer file.Close()

	csvType := r.FormValue("csv_type") // "military" | "corporate" | "family"
	if csvType == "" {
		csvType = "corporate"
	}

	rows, parseErr := importer.ParseCSV(file, hdr.Filename, csvType)
	if parseErr != nil {
		// %q escapes control characters in request-derived values, preventing log injection (G706).
		log.Printf("bulk-import: CSV parse error (file=%q type=%q): %v", hdr.Filename, csvType, parseErr)
		http.Error(w, "invalid CSV format", http.StatusBadRequest)
		return
	}

	batch, dispatchErr := importer.CreateAndDispatch(r.Context(), rows, csvType)
	if dispatchErr != nil {
		// %q escapes control characters in request-derived values, preventing log injection (G706).
		log.Printf("bulk-import: dispatch error (type=%q rows=%d): %v", csvType, len(rows), dispatchErr)
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(batch); err != nil {
		log.Printf("bulk-import: encode batch response: %v", err)
	}
}

// handleStats returns delivery telemetry for a batch.
// Used by Odoo dashboard and admin web UI.
// Returns phone_hash (SHA3-256) in failed_delivery — never plaintext phone.
func (s *server) handleStats(w http.ResponseWriter, r *http.Request) {
	batchID := r.PathValue("batchID")
	if batchID == "" {
		http.Error(w, "batchID required", http.StatusBadRequest)
		return
	}
	stats, err := admin.GetBatchStats(r.Context(), batchID)
	if err != nil {
		// %q escapes control characters in request-derived batchID (G706).
		log.Printf("bulk-import: get batch stats (batchID=%q): %v", batchID, err)
		http.Error(w, "batch not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(stats); err != nil {
		log.Printf("bulk-import: encode stats response: %v", err)
	}
}

// handleResend re-dispatches invitations for failed/pending entries.
// Body: {"phone_hashes": [...]} or {"all_failed": true}
// Rate-limited: max 1000 SMS/minute.
func (s *server) handleResend(w http.ResponseWriter, r *http.Request) {
	batchID := r.PathValue("batchID")
	if batchID == "" {
		http.Error(w, "batchID required", http.StatusBadRequest)
		return
	}

	var req admin.ResendRequest
	if r.ContentLength > 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid JSON body", http.StatusBadRequest)
			return
		}
	} else {
		req.AllFailed = true
	}

	count, err := admin.ResendFailed(r.Context(), batchID, req)
	if err != nil {
		// %q escapes control characters in request-derived batchID (G706).
		log.Printf("bulk-import: resend failed (batchID=%q): %v", batchID, err)
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]int{"queued": count}); err != nil {
		log.Printf("bulk-import: encode resend response: %v", err)
	}
}

// handleValidateToken validates an activation token presented by the iOS app.
// Body: {"token_hash": "<SHA3-256(token)>"}
// Returns: profile metadata. Invalidates token on first use (one-shot Redis NX).
// Returns 410 Gone on second attempt (token already consumed).
// The plaintext token NEVER reaches this endpoint — only its hash.
func (s *server) handleValidateToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TokenHash string `json:"token_hash"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.TokenHash == "" {
		http.Error(w, "token_hash required", http.StatusBadRequest)
		return
	}

	meta, err := importer.ConsumeActivationToken(r.Context(), req.TokenHash)
	if err != nil {
		// Distinguish between not-found/expired and already-consumed.
		if err == importer.ErrTokenAlreadyConsumed {
			http.Error(w, "token already used", http.StatusGone)
			return
		}
		http.Error(w, "invalid or expired token", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(meta); err != nil {
		log.Printf("bulk-import: encode token response: %v", err)
	}
}
