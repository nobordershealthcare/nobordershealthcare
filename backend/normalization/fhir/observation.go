package fhir

import (
	"encoding/json"
	"net/http"

	"github.com/nobordershealthcare/normalization/cdr"
	"github.com/nobordershealthcare/normalization/lookup"
)

// ObservationHandler handles GET /fhir/Observation?patient={hash}&code={loinc}
type ObservationHandler struct {
	reader *cdr.Reader
}

// Handle returns a FHIR Bundle of Observation resources for the requested patient
// and LOINC code. The `code` parameter is validated against the LOINC lookup table
// before the CDR is queried — unknown codes get a 422, not a CDR miss.
func (h *ObservationHandler) Handle(w http.ResponseWriter, r *http.Request) {
	userHash := r.URL.Query().Get("patient")
	loincCode := r.URL.Query().Get("code")

	// Validate LOINC code against the lookup table.
	// NEVER query the CDR with an unrecognised code.
	if loincCode != "" {
		if _, ok := lookup.LookupLOINC(lookup.LOINCCode(loincCode)); !ok {
			http.Error(w, "unknown LOINC code — not in normalization table", http.StatusUnprocessableEntity)
			return
		}
	}

	var (
		comps []*cdr.Composition
		err   error
	)

	if loincCode != "" {
		comps, err = h.reader.ObservationsByLOINC(r.Context(), userHash, loincCode)
	} else {
		// No code filter: return all observations for the patient.
		comps, err = h.reader.CompositionsByType(r.Context(), userHash, string(cdr.TypeObservation))
	}

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
		obs := ObservationFromComposition(comp, userHash, hashPrefix(comp))
		bundle.Entry = append(bundle.Entry, BundleEntry{Resource: obs})
	}

	body, err := json.Marshal(bundle)
	if err != nil {
		http.Error(w, "marshal error", http.StatusInternalServerError)
		return
	}
	writeFHIRJSON(w, http.StatusOK, body)
}
