package fhir

import (
	"encoding/json"
	"net/http"

	"github.com/nobordershealthcare/normalization/cdr"
)

// ConditionHandler handles GET /fhir/Condition?patient={hash}
type ConditionHandler struct {
	reader *cdr.Reader
}

func (h *ConditionHandler) Handle(w http.ResponseWriter, r *http.Request) {
	userHash := r.URL.Query().Get("patient")

	comps, err := h.reader.CompositionsByType(r.Context(), userHash, string(cdr.TypeCondition))
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
		cond := ConditionFromComposition(comp, userHash, hashPrefix(comp))
		bundle.Entry = append(bundle.Entry, BundleEntry{Resource: cond})
	}

	body, err := json.Marshal(bundle)
	if err != nil {
		http.Error(w, "marshal error", http.StatusInternalServerError)
		return
	}
	writeFHIRJSON(w, http.StatusOK, body)
}
