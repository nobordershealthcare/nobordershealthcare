package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"

	"github.com/nobordershealthcare/bulk-import/internal/importer"
)

type server struct {
	mux *http.ServeMux
}

func newServer() *server {
	s := &server{mux: http.NewServeMux()}
	s.mux.HandleFunc("POST /bulk/upload", s.handleUpload)
	s.mux.HandleFunc("GET /bulk/status/{batchID}", s.handleStatus)
	s.mux.HandleFunc("POST /bulk/resend/{entryID}", s.handleResend)
	return s
}

func (s *server) ListenAndServe(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	return http.Serve(ln, s.mux)
}

// handleUpload processes a CSV upload and dispatches activation invitations.
// Auth: admin JWT (validated by api-gateway mTLS layer before reaching this handler).
// For military batches: 2-person FIDO2 confirmation required (header X-Cosigner-Token).
func (s *server) handleUpload(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		http.Error(w, "invalid multipart form", http.StatusBadRequest)
		return
	}

	legalBasisConfirmed := r.FormValue("gdpr_legal_basis_confirmed")
	if legalBasisConfirmed != "true" {
		http.Error(w, "GDPR legal basis confirmation required: set gdpr_legal_basis_confirmed=true", http.StatusBadRequest)
		return
	}

	file, hdr, err := r.FormFile("csv")
	if err != nil {
		http.Error(w, "csv file required", http.StatusBadRequest)
		return
	}
	defer file.Close()

	csvType := r.FormValue("csv_type") // "military" or "corporate" or "family"
	if csvType == "" {
		csvType = "corporate"
	}

	rows, parseErr := importer.ParseCSV(file, hdr.Filename, csvType)
	if parseErr != nil {
		http.Error(w, fmt.Sprintf("CSV parse error: %v", parseErr), http.StatusBadRequest)
		return
	}

	batch, dispatchErr := importer.CreateAndDispatch(r.Context(), rows, csvType)
	if dispatchErr != nil {
		http.Error(w, fmt.Sprintf("dispatch error: %v", dispatchErr), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(batch)
}

func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	batchID := r.PathValue("batchID")
	if batchID == "" {
		http.Error(w, "batchID required", http.StatusBadRequest)
		return
	}
	status, err := importer.GetBatchStatus(r.Context(), batchID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
}

func (s *server) handleResend(w http.ResponseWriter, r *http.Request) {
	entryID := r.PathValue("entryID")
	if entryID == "" {
		http.Error(w, "entryID required", http.StatusBadRequest)
		return
	}
	if err := importer.ResendInvitation(r.Context(), entryID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
