package fhir

import (
	"crypto/ed25519"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/nobordershealthcare/normalization/cdr"
)

// NewRouter builds the FHIR R4 Search API router.
//
// All routes share the Auth middleware. Individual routes apply their own
// scope or role requirement.
//
// mTLS termination is handled by the Istio service mesh sidecar; the router
// trusts that only mTLS-authenticated requests reach this process.
func NewRouter(pubKey ed25519.PublicKey, reader *cdr.Reader) http.Handler {
	mw := NewMiddleware(pubKey)

	r := chi.NewRouter()

	// Shared middleware applied to every request.
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)
	r.Use(mw.Auth)          // JWT EdDSA verification, rate limit
	r.Use(ValidatePatientHash) // ?patient= must be 64-hex

	obs := &ObservationHandler{reader: reader}
	cond := &ConditionHandler{reader: reader}
	med := &MedicationHandler{reader: reader}
	allergy := &AllergyHandler{reader: reader}
	summary := &SummaryHandler{reader: reader}

	// GET /fhir/Observation?patient={hash}&code={loinc}
	r.With(RequireScope("observations")).Get("/fhir/Observation", obs.Handle)

	// GET /fhir/Condition?patient={hash}
	r.With(RequireScope("diagnoses")).Get("/fhir/Condition", cond.Handle)

	// GET /fhir/MedicationStatement?patient={hash}
	r.With(RequireScope("medications")).Get("/fhir/MedicationStatement", med.Handle)

	// GET /fhir/AllergyIntolerance?patient={hash}
	r.With(RequireScope("allergies")).Get("/fhir/AllergyIntolerance", allergy.Handle)

	// GET /fhir/$summary?patient={hash}  — IPS, requires er_doctor or patient role
	r.With(RequireRole("er_doctor", "patient")).Get("/fhir/$summary", summary.Handle)

	return r
}
