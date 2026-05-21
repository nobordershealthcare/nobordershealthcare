// Package fhir implements the FHIR R4 Search API for the normalization service.
//
// All patient references use SHA3-256(userID) as the identifier — no real name,
// DOB, or national ID ever appears in any FHIR resource returned by this API.
//
// Content type: application/fhir+json (FHIR MIME type per R4 spec).
package fhir

import (
	"time"

	"github.com/nobordershealthcare/normalization/cdr"
	"github.com/nobordershealthcare/normalization/lookup"
)

// FHIRMediaType is the required Accept / Content-Type for all FHIR endpoints.
const FHIRMediaType = "application/fhir+json"

// ── Shared FHIR R4 structural types ──────────────────────────────────────────

type Coding struct {
	System  string `json:"system"`
	Code    string `json:"code"`
	Display string `json:"display,omitempty"`
}

type CodeableConcept struct {
	Coding []Coding `json:"coding"`
	Text   string   `json:"text,omitempty"`
}

type Reference struct {
	Reference string `json:"reference"`
}

type Quantity struct {
	Value  float64 `json:"value"`
	Unit   string  `json:"unit"`
	System string  `json:"system,omitempty"`
	Code   string  `json:"code,omitempty"`
}

type BundleEntry struct {
	Resource interface{} `json:"resource"`
}

type Bundle struct {
	ResourceType string        `json:"resourceType"`
	ID           string        `json:"id"`
	Type         string        `json:"type"`
	Timestamp    string        `json:"timestamp"`
	Total        int           `json:"total,omitempty"`
	Entry        []BundleEntry `json:"entry"`
}

// ── FHIR R4 resource types ────────────────────────────────────────────────────

type Observation struct {
	ResourceType      string            `json:"resourceType"`
	ID                string            `json:"id"`
	Status            string            `json:"status"`
	Category          []CodeableConcept `json:"category"`
	Code              CodeableConcept   `json:"code"`
	Subject           Reference         `json:"subject"`
	EffectiveDateTime string            `json:"effectiveDateTime,omitempty"`
	ValueQuantity     *Quantity         `json:"valueQuantity,omitempty"`
	ValueString       string            `json:"valueString,omitempty"`
}

type Condition struct {
	ResourceType   string          `json:"resourceType"`
	ID             string          `json:"id"`
	ClinicalStatus CodeableConcept `json:"clinicalStatus"`
	Code           CodeableConcept `json:"code"`
	Subject        Reference       `json:"subject"`
	RecordedDate   string          `json:"recordedDate,omitempty"`
}

type MedicationStatement struct {
	ResourceType              string          `json:"resourceType"`
	ID                        string          `json:"id"`
	Status                    string          `json:"status"`
	MedicationCodeableConcept CodeableConcept `json:"medicationCodeableConcept"`
	Subject                   Reference       `json:"subject"`
	EffectiveDateTime         string          `json:"effectiveDateTime,omitempty"`
}

type AllergyIntolerance struct {
	ResourceType   string          `json:"resourceType"`
	ID             string          `json:"id"`
	ClinicalStatus CodeableConcept `json:"clinicalStatus"`
	Criticality    string          `json:"criticality,omitempty"`
	Code           CodeableConcept `json:"code"`
	Patient        Reference       `json:"patient"`
	RecordedDate   string          `json:"recordedDate,omitempty"`
}

// ── Composition builders ──────────────────────────────────────────────────────

// patientRef returns a de-identified FHIR Patient reference.
// The reference uses SHA3-256(userID) as the logical ID — no real identity.
func patientRef(userHash string) Reference {
	return Reference{Reference: "Patient/" + userHash}
}

// ObservationFromComposition converts a cdr.Composition to a FHIR Observation.
func ObservationFromComposition(comp *cdr.Composition, userHash, docHashPrefix string) Observation {
	entry, ok := lookup.LookupLOINC(lookup.LOINCCode(comp.LOINCCode))

	category := "laboratory"
	if ok {
		category = entry.Category
	}

	obs := Observation{
		ResourceType: "Observation",
		ID:           docHashPrefix,
		Status:       comp.Status,
		Category: []CodeableConcept{{
			Coding: []Coding{{
				System: "http://terminology.hl7.org/CodeSystem/observation-category",
				Code:   category,
			}},
		}},
		Code: CodeableConcept{Coding: []Coding{{
			System:  "http://loinc.org",
			Code:    comp.LOINCCode,
			Display: shortName(ok, entry.ShortName, comp.LOINCCode),
		}}},
		Subject:           patientRef(userHash),
		EffectiveDateTime: formatTime(comp.RecordedAt),
	}

	if comp.ValueNum != nil {
		obs.ValueQuantity = &Quantity{
			Value:  *comp.ValueNum,
			Unit:   comp.Unit,
			System: "http://unitsofmeasure.org",
			Code:   comp.Unit,
		}
	} else if comp.ValueStr != "" {
		obs.ValueString = comp.ValueStr
	}

	return obs
}

// ConditionFromComposition converts a cdr.Composition to a FHIR Condition.
func ConditionFromComposition(comp *cdr.Composition, userHash, docHashPrefix string) Condition {
	display := comp.ICD10Code
	if entry, ok := lookup.LookupICD10(lookup.ICD10Code(comp.ICD10Code)); ok {
		display = entry.Display
	}

	coding := []Coding{{
		System:  "http://hl7.org/fhir/sid/icd-10",
		Code:    comp.ICD10Code,
		Display: display,
	}}
	if comp.SNOMEDCode != "" && comp.SNOMEDCode != lookup.UnknownCode {
		if se, ok := lookup.LookupSNOMED(lookup.SNOMEDCode(comp.SNOMEDCode)); ok {
			coding = append(coding, Coding{
				System:  "http://snomed.info/sct",
				Code:    comp.SNOMEDCode,
				Display: se.Display,
			})
		}
	}

	return Condition{
		ResourceType: "Condition",
		ID:           docHashPrefix,
		ClinicalStatus: CodeableConcept{Coding: []Coding{{
			System: "http://terminology.hl7.org/CodeSystem/condition-clinical",
			Code:   comp.Status,
		}}},
		Code:         CodeableConcept{Coding: coding},
		Subject:      patientRef(userHash),
		RecordedDate: formatTime(comp.RecordedAt),
	}
}

// MedicationFromComposition converts a cdr.Composition to a FHIR MedicationStatement.
func MedicationFromComposition(comp *cdr.Composition, userHash, docHashPrefix string) MedicationStatement {
	display := comp.ATCCode
	if entry, ok := lookup.ATCEntryByCode(lookup.ATCCode(comp.ATCCode)); ok {
		display = entry.Name
	}

	return MedicationStatement{
		ResourceType: "MedicationStatement",
		ID:           docHashPrefix,
		Status:       comp.Status,
		MedicationCodeableConcept: CodeableConcept{Coding: []Coding{{
			System:  "http://www.whocc.no/atc",
			Code:    comp.ATCCode,
			Display: display,
		}}},
		Subject:           patientRef(userHash),
		EffectiveDateTime: formatTime(comp.RecordedAt),
	}
}

// AllergyFromComposition converts a cdr.Composition to a FHIR AllergyIntolerance.
func AllergyFromComposition(comp *cdr.Composition, userHash, docHashPrefix string) AllergyIntolerance {
	display := comp.SNOMEDCode
	if entry, ok := lookup.LookupSNOMED(lookup.SNOMEDCode(comp.SNOMEDCode)); ok {
		display = entry.Display
	}

	return AllergyIntolerance{
		ResourceType: "AllergyIntolerance",
		ID:           docHashPrefix,
		ClinicalStatus: CodeableConcept{Coding: []Coding{{
			System: "http://terminology.hl7.org/CodeSystem/allergyintolerance-clinical",
			Code:   comp.Status,
		}}},
		Code: CodeableConcept{Coding: []Coding{{
			System:  "http://snomed.info/sct",
			Code:    comp.SNOMEDCode,
			Display: display,
		}}},
		Patient:      patientRef(userHash),
		RecordedDate: formatTime(comp.RecordedAt),
	}
}

// ── Utilities ─────────────────────────────────────────────────────────────────

func formatTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func shortName(ok bool, name, fallback string) string {
	if ok {
		return name
	}
	return fallback
}
