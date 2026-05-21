package fhir

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/nobordershealthcare/normalization/cdr"
	"github.com/nobordershealthcare/normalization/i18n"
)

// SummaryHandler handles GET /fhir/$summary?patient={hash}
// Returns an IPS (International Patient Summary) Bundle (type=document).
//
// The locale is read from the JWT "locale" claim via context so section
// headings are rendered in the requester's language. LOINC/ATC codes are
// language-independent and never translated.
//
// Access: restricted to role "er_doctor" or "patient" (enforced by router).
type SummaryHandler struct {
	reader *cdr.Reader
}

// ipsComposition is the FHIR Composition resource that anchors the IPS bundle.
type ipsComposition struct {
	ResourceType string              `json:"resourceType"`
	ID           string              `json:"id"`
	Status       string              `json:"status"`
	Type         CodeableConcept     `json:"type"`
	Subject      Reference           `json:"subject"`
	Date         string              `json:"date"`
	Title        string              `json:"title"`
	Section      []ipsSection        `json:"section"`
}

type ipsSection struct {
	Title string        `json:"title"`
	Code  CodeableConcept `json:"code"`
	Entry []Reference    `json:"entry"`
}

func (h *SummaryHandler) Handle(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userHash := r.URL.Query().Get("patient")
	locale := localeFromCtx(ctx)
	labels := i18n.ForLocale(locale)

	// Fetch all compositions for the patient in one CDR read.
	allComps, err := h.reader.AllCompositions(ctx, userHash)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// Partition by type.
	var (
		observations []*cdr.Composition
		conditions   []*cdr.Composition
		medications  []*cdr.Composition
		allergies    []*cdr.Composition
	)
	for _, comp := range allComps {
		switch cdr.CompositionType(comp.Type) {
		case cdr.TypeObservation:
			observations = append(observations, comp)
		case cdr.TypeCondition:
			conditions = append(conditions, comp)
		case cdr.TypeMedicationStatement:
			medications = append(medications, comp)
		case cdr.TypeAllergyIntolerance:
			allergies = append(allergies, comp)
		}
	}

	bundleID := uuid.NewString()
	compID := uuid.NewString()
	now := time.Now().UTC().Format(time.RFC3339)

	// Build FHIR resources and section references simultaneously.
	entries := []BundleEntry{}

	// ── Medication Summary section ────────────────────────────────────────────
	var medRefs []Reference
	for _, comp := range medications {
		prefix := hashPrefix(comp)
		med := MedicationFromComposition(comp, userHash, prefix)
		entries = append(entries, BundleEntry{Resource: med})
		medRefs = append(medRefs, Reference{Reference: "MedicationStatement/" + prefix})
	}

	// ── Allergies section ─────────────────────────────────────────────────────
	var allergyRefs []Reference
	for _, comp := range allergies {
		prefix := hashPrefix(comp)
		allergy := AllergyFromComposition(comp, userHash, prefix)
		entries = append(entries, BundleEntry{Resource: allergy})
		allergyRefs = append(allergyRefs, Reference{Reference: "AllergyIntolerance/" + prefix})
	}

	// ── Problem List section ──────────────────────────────────────────────────
	var condRefs []Reference
	for _, comp := range conditions {
		prefix := hashPrefix(comp)
		cond := ConditionFromComposition(comp, userHash, prefix)
		entries = append(entries, BundleEntry{Resource: cond})
		condRefs = append(condRefs, Reference{Reference: "Condition/" + prefix})
	}

	// ── Results and Vital Signs sections ─────────────────────────────────────
	var labRefs, vitalRefs []Reference
	for _, comp := range observations {
		prefix := hashPrefix(comp)
		obs := ObservationFromComposition(comp, userHash, prefix)
		entries = append(entries, BundleEntry{Resource: obs})
		ref := Reference{Reference: "Observation/" + prefix}
		if obs.Category[0].Coding[0].Code == "vital-signs" {
			vitalRefs = append(vitalRefs, ref)
		} else {
			labRefs = append(labRefs, ref)
		}
	}

	// ── Build IPS Composition ─────────────────────────────────────────────────
	comp := ipsComposition{
		ResourceType: "Composition",
		ID:           compID,
		Status:       "final",
		Type: CodeableConcept{Coding: []Coding{{
			System:  "http://loinc.org",
			Code:    "60591-5",
			Display: "Patient Summary",
		}}},
		Subject: patientRef(userHash),
		Date:    now,
		Title:   "International Patient Summary",
		Section: []ipsSection{
			{
				Title: labels.MedicationSummary,
				Code: CodeableConcept{Coding: []Coding{{
					System: "http://loinc.org", Code: "10160-0",
					Display: "History of Medication use Narrative",
				}}},
				Entry: medRefs,
			},
			{
				Title: labels.AllergiesAndIntolerances,
				Code: CodeableConcept{Coding: []Coding{{
					System: "http://loinc.org", Code: "48765-2",
					Display: "Allergies and adverse reactions Document",
				}}},
				Entry: allergyRefs,
			},
			{
				Title: labels.ProblemList,
				Code: CodeableConcept{Coding: []Coding{{
					System: "http://loinc.org", Code: "11450-4",
					Display: "Problem list - Reported",
				}}},
				Entry: condRefs,
			},
			{
				Title: labels.Results,
				Code: CodeableConcept{Coding: []Coding{{
					System: "http://loinc.org", Code: "30954-2",
					Display: "Relevant diagnostic tests/laboratory data Narrative",
				}}},
				Entry: labRefs,
			},
			{
				Title: labels.VitalSigns,
				Code: CodeableConcept{Coding: []Coding{{
					System: "http://loinc.org", Code: "8716-3",
					Display: "Vital signs",
				}}},
				Entry: vitalRefs,
			},
		},
	}

	// Composition is always the first entry in an IPS bundle.
	allEntries := append([]BundleEntry{{Resource: comp}}, entries...)

	bundle := Bundle{
		ResourceType: "Bundle",
		ID:           bundleID,
		Type:         "document",
		Timestamp:    now,
		Entry:        allEntries,
	}

	body, err := json.Marshal(bundle)
	if err != nil {
		http.Error(w, "marshal error", http.StatusInternalServerError)
		return
	}
	writeFHIRJSON(w, http.StatusOK, body)
}
