package fhir

import (
	"encoding/json"
	"net/http"

	"github.com/nobordershealthcare/normalization/cdr"
)

// MedicationHandler handles GET /fhir/MedicationStatement?patient={hash}
type MedicationHandler struct {
	reader *cdr.Reader
}

func (h *MedicationHandler) Handle(w http.ResponseWriter, r *http.Request) {
	userHash := r.URL.Query().Get("patient")

	comps, err := h.reader.CompositionsByType(r.Context(), userHash, string(cdr.TypeMedicationStatement))
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	bundle := Bundle{
		ResourceType: "Bundle",
		ID:           newBundleID(),
		Type:         "searchset",
		Timestamp:    nowRFC3339(),
		Total:        len(comps),
		Entry:        make([]BundleEntry, 0, len(comps)),
	}

	for _, comp := range comps {
		med := MedicationFromComposition(comp, userHash, hashPrefix(comp))
		bundle.Entry = append(bundle.Entry, BundleEntry{Resource: med})
	}

	body, err := json.Marshal(bundle)
	if err != nil {
		http.Error(w, "marshal error", http.StatusInternalServerError)
		return
	}
	writeFHIRJSON(w, http.StatusOK, body)
}
