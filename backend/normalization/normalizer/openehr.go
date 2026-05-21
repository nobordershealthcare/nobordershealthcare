// Package normalizer converts raw clinical events (from Kafka) into normalized
// cdr.Composition values suitable for ScyllaDB storage.
//
// CRITICAL: No generative AI or external API may be used for code inference.
// Unknown codes → UnknownCode sentinel + ReviewFlag. Always.
package normalizer

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/nobordershealthcare/normalization/cdr"
	"github.com/nobordershealthcare/normalization/lookup"
)

// ── Raw clinical item types ───────────────────────────────────────────────────
// These intermediate types carry the parsed (but not yet normalized) data
// extracted from source documents before lookup table resolution.

// RawObservation is a lab or vital-sign value extracted from a source document.
type RawObservation struct {
	LOINCCode  string
	ValueNum   *float64
	ValueStr   string
	Unit       string
	Status     string // "final" | "preliminary"
	RecordedAt time.Time
}

// RawCondition is a diagnosis extracted from a source document.
type RawCondition struct {
	ICD10Code  string
	SNOMEDCode string
	Status     string // "active" | "resolved" | "inactive"
	RecordedAt time.Time
}

// RawMedication is a medication statement extracted from a source document.
type RawMedication struct {
	DrugName   string // used for ATC name-lookup when ATCCode is empty
	ATCCode    string // may be pre-coded or empty
	Status     string // "active" | "stopped" | "unknown"
	RecordedAt time.Time
}

// RawAllergy is an allergy/intolerance extracted from a source document.
type RawAllergy struct {
	SubstanceName string // used for SNOMED name-lookup when SNOMEDCode is empty
	SNOMEDCode    string // may be pre-coded or empty
	Criticality   string // "high" | "low" | "unable-to-assess"
	Status        string // "active" | "resolved"
	RecordedAt    time.Time
}

// ── Composition builders ──────────────────────────────────────────────────────

// BuildObservationComposition creates a cdr.Composition for a lab observation.
// If the LOINC code is not in the lookup table, ReviewRequired is set and a
// ReviewFlag is returned alongside the composition.
func BuildObservationComposition(
	obs *RawObservation,
	eventID, userHash, docHash, sourceHash string,
) (*cdr.Composition, *lookup.ReviewFlag) {

	entry, flag := lookup.ResolveLOINC(lookup.LOINCCode(obs.LOINCCode), eventID, userHash, docHash)

	loincCode := obs.LOINCCode
	if flag != nil {
		loincCode = lookup.UnknownCode
	}

	unit := obs.Unit
	if unit == "" && flag == nil {
		unit = entry.UCUMUnit // canonical UCUM unit from lookup table
	}

	return &cdr.Composition{
		Version:        cdr.CompositionVersion,
		Type:           string(cdr.TypeObservation),
		LOINCCode:      loincCode,
		ValueNum:       obs.ValueNum,
		ValueStr:       obs.ValueStr,
		Unit:           unit,
		Status:         obs.Status,
		ReviewRequired: flag != nil,
		SourceHash:     sourceHash,
		RecordedAt:     obs.RecordedAt,
	}, flag
}

// BuildConditionComposition creates a cdr.Composition for a diagnosis.
func BuildConditionComposition(
	cond *RawCondition,
	eventID, userHash, docHash, sourceHash string,
) (*cdr.Composition, []*lookup.ReviewFlag) {

	var flags []*lookup.ReviewFlag

	icdEntry, icdFlag := lookup.ResolveICD10(lookup.ICD10Code(cond.ICD10Code), eventID, userHash, docHash)
	if icdFlag != nil {
		flags = append(flags, icdFlag)
	}
	icd10Code := string(icdEntry.Code)
	if icd10Code == "" {
		icd10Code = lookup.UnknownCode
	}

	snomedCode := cond.SNOMEDCode
	if snomedCode != "" {
		_, snomedFlag := lookup.ResolveSNOMED(lookup.SNOMEDCode(snomedCode), eventID, userHash, docHash)
		if snomedFlag != nil {
			flags = append(flags, snomedFlag)
			snomedCode = lookup.UnknownCode
		}
	}

	return &cdr.Composition{
		Version:        cdr.CompositionVersion,
		Type:           string(cdr.TypeCondition),
		ICD10Code:      icd10Code,
		SNOMEDCode:     snomedCode,
		Status:         cond.Status,
		ReviewRequired: len(flags) > 0,
		SourceHash:     sourceHash,
		RecordedAt:     cond.RecordedAt,
	}, flags
}

// BuildMedicationComposition creates a cdr.Composition for a medication.
// ATC resolution: if ATCCode is pre-coded in the source, validate it exists;
// otherwise look up by DrugName. Either way, unknown → UNKNOWN + ReviewFlag.
func BuildMedicationComposition(
	med *RawMedication,
	eventID, userHash, docHash, sourceHash string,
) (*cdr.Composition, *lookup.ReviewFlag) {

	var (
		atcCode string
		flag    *lookup.ReviewFlag
	)

	if med.ATCCode != "" {
		if _, ok := lookup.ATCEntryByCode(lookup.ATCCode(med.ATCCode)); ok {
			atcCode = med.ATCCode
		} else {
			atcCode = lookup.UnknownCode
			flag = &lookup.ReviewFlag{
				EventID:     eventID,
				UserHash:    userHash,
				DocHash:     docHash,
				UnknownCode: med.ATCCode,
				CodeSystem:  lookup.CodeSystemATC,
			}
		}
	} else {
		resolvedCode, f := lookup.ResolveATC(med.DrugName, eventID, userHash, docHash)
		flag = f
		if f != nil {
			atcCode = lookup.UnknownCode
		} else {
			atcCode = string(resolvedCode)
		}
	}

	return &cdr.Composition{
		Version:        cdr.CompositionVersion,
		Type:           string(cdr.TypeMedicationStatement),
		ATCCode:        atcCode,
		Status:         med.Status,
		ReviewRequired: flag != nil,
		SourceHash:     sourceHash,
		RecordedAt:     med.RecordedAt,
	}, flag
}

// BuildAllergyComposition creates a cdr.Composition for an allergy/intolerance.
func BuildAllergyComposition(
	allergy *RawAllergy,
	eventID, userHash, docHash, sourceHash string,
) (*cdr.Composition, *lookup.ReviewFlag) {

	var (
		snomedCode string
		flag       *lookup.ReviewFlag
	)

	switch {
	case allergy.SNOMEDCode != "":
		entry, f := lookup.ResolveSNOMED(lookup.SNOMEDCode(allergy.SNOMEDCode), eventID, userHash, docHash)
		if f != nil {
			snomedCode = lookup.UnknownCode
			flag = f
		} else {
			snomedCode = string(entry.Code)
		}
	case allergy.SubstanceName != "":
		code, ok := lookup.LookupSNOMEDByName(allergy.SubstanceName)
		if !ok {
			snomedCode = lookup.UnknownCode
			flag = &lookup.ReviewFlag{
				EventID:     eventID,
				UserHash:    userHash,
				DocHash:     docHash,
				UnknownCode: allergy.SubstanceName,
				CodeSystem:  lookup.CodeSystemSNOMED,
			}
		} else {
			snomedCode = string(code)
		}
	default:
		snomedCode = lookup.UnknownCode
		flag = &lookup.ReviewFlag{
			EventID:     eventID,
			UserHash:    userHash,
			DocHash:     docHash,
			UnknownCode: "(no substance provided)",
			CodeSystem:  lookup.CodeSystemSNOMED,
		}
	}

	return &cdr.Composition{
		Version:        cdr.CompositionVersion,
		Type:           string(cdr.TypeAllergyIntolerance),
		SNOMEDCode:     snomedCode,
		Status:         allergy.Status,
		ReviewRequired: flag != nil,
		SourceHash:     sourceHash,
		RecordedAt:     allergy.RecordedAt,
	}, flag
}

// ── FHIR R4 Bundle parser ─────────────────────────────────────────────────────

// codingEntry is the shared type for all FHIR coding arrays.
// Using a named type ensures extractCode works across all resource parsers
// without struct-literal type mismatches.
type codingEntry struct {
	System  string `json:"system"`
	Code    string `json:"code"`
	Display string `json:"display"` // present in some resources; ignored during lookup
}

// ParseFHIRR4Bundle extracts raw clinical items from a FHIR R4 Bundle document.
// Only explicit codes are extracted — nothing is inferred or generated.
// Unsupported resource types are silently skipped.
func ParseFHIRR4Bundle(raw []byte) ([]RawObservation, []RawCondition, []RawMedication, []RawAllergy, error) {
	var bundle struct {
		ResourceType string `json:"resourceType"`
		Entry        []struct {
			Resource json.RawMessage `json:"resource"`
		} `json:"entry"`
	}
	if err := json.Unmarshal(raw, &bundle); err != nil {
		return nil, nil, nil, nil, fmt.Errorf("parse FHIR bundle: %w", err)
	}
	if bundle.ResourceType != "Bundle" {
		return nil, nil, nil, nil, fmt.Errorf("parse FHIR bundle: expected Bundle, got %q", bundle.ResourceType)
	}

	var (
		obs      []RawObservation
		conds    []RawCondition
		meds     []RawMedication
		allergies []RawAllergy
	)

	for _, entry := range bundle.Entry {
		var typed struct {
			ResourceType string `json:"resourceType"`
		}
		if err := json.Unmarshal(entry.Resource, &typed); err != nil {
			continue
		}

		switch typed.ResourceType {
		case "Observation":
			if o, err := parseFHIRObservation(entry.Resource); err == nil {
				obs = append(obs, o)
			}
		case "Condition":
			if c, err := parseFHIRCondition(entry.Resource); err == nil {
				conds = append(conds, c)
			}
		case "MedicationStatement":
			if m, err := parseFHIRMedication(entry.Resource); err == nil {
				meds = append(meds, m)
			}
		case "AllergyIntolerance":
			if a, err := parseFHIRAllergy(entry.Resource); err == nil {
				allergies = append(allergies, a)
			}
		}
	}

	return obs, conds, meds, allergies, nil
}

// ── Internal FHIR sub-parsers ─────────────────────────────────────────────────

func parseFHIRObservation(raw json.RawMessage) (RawObservation, error) {
	var r struct {
		Status string `json:"status"`
		Code   struct {
			Coding []codingEntry `json:"coding"`
		} `json:"code"`
		ValueQuantity *struct {
			Value float64 `json:"value"`
			Unit  string  `json:"unit"`
			Code  string  `json:"code"` // UCUM code preferred over display unit
		} `json:"valueQuantity"`
		ValueString       string `json:"valueString"`
		EffectiveDateTime string `json:"effectiveDateTime"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return RawObservation{}, err
	}

	o := RawObservation{
		LOINCCode:  extractCode(r.Code.Coding, "http://loinc.org"),
		Status:     r.Status,
		ValueStr:   r.ValueString,
		RecordedAt: parseDateTime(r.EffectiveDateTime),
	}
	if r.ValueQuantity != nil {
		v := r.ValueQuantity.Value
		o.ValueNum = &v
		if r.ValueQuantity.Code != "" {
			o.Unit = r.ValueQuantity.Code
		} else {
			o.Unit = r.ValueQuantity.Unit
		}
	}
	return o, nil
}

func parseFHIRCondition(raw json.RawMessage) (RawCondition, error) {
	var r struct {
		ClinicalStatus struct {
			Coding []codingEntry `json:"coding"`
		} `json:"clinicalStatus"`
		Code struct {
			Coding []codingEntry `json:"coding"`
		} `json:"code"`
		RecordedDate string `json:"recordedDate"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return RawCondition{}, err
	}

	status := "active"
	if len(r.ClinicalStatus.Coding) > 0 {
		status = r.ClinicalStatus.Coding[0].Code
	}

	return RawCondition{
		ICD10Code:  extractCode(r.Code.Coding, "http://hl7.org/fhir/sid/icd-10"),
		SNOMEDCode: extractCode(r.Code.Coding, "http://snomed.info/sct"),
		Status:     status,
		RecordedAt: parseDateTime(r.RecordedDate),
	}, nil
}

func parseFHIRMedication(raw json.RawMessage) (RawMedication, error) {
	var r struct {
		Status                   string `json:"status"`
		MedicationCodeableConcept *struct {
			Coding []codingEntry `json:"coding"`
			Text   string        `json:"text"`
		} `json:"medicationCodeableConcept"`
		EffectiveDateTime string `json:"effectiveDateTime"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return RawMedication{}, err
	}

	med := RawMedication{Status: r.Status, RecordedAt: parseDateTime(r.EffectiveDateTime)}
	if r.MedicationCodeableConcept != nil {
		med.ATCCode = extractCode(r.MedicationCodeableConcept.Coding, "http://www.whocc.no/atc")
		med.DrugName = r.MedicationCodeableConcept.Text
		if med.DrugName == "" && len(r.MedicationCodeableConcept.Coding) > 0 {
			med.DrugName = r.MedicationCodeableConcept.Coding[0].Display
		}
	}
	return med, nil
}

func parseFHIRAllergy(raw json.RawMessage) (RawAllergy, error) {
	var r struct {
		ClinicalStatus struct {
			Coding []codingEntry `json:"coding"`
		} `json:"clinicalStatus"`
		Criticality string `json:"criticality"`
		Code        struct {
			Coding []codingEntry `json:"coding"`
			Text   string        `json:"text"`
		} `json:"code"`
		RecordedDate string `json:"recordedDate"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return RawAllergy{}, err
	}

	status := "active"
	if len(r.ClinicalStatus.Coding) > 0 {
		status = r.ClinicalStatus.Coding[0].Code
	}

	a := RawAllergy{
		SNOMEDCode:    extractCode(r.Code.Coding, "http://snomed.info/sct"),
		SubstanceName: r.Code.Text,
		Criticality:   r.Criticality,
		Status:        status,
		RecordedAt:    parseDateTime(r.RecordedDate),
	}
	if a.SubstanceName == "" && len(r.Code.Coding) > 0 {
		a.SubstanceName = r.Code.Coding[0].Display
	}
	return a, nil
}

// ── Utilities ─────────────────────────────────────────────────────────────────

// extractCode returns the first code value whose System URI matches.
// Returns "" if no matching system is found.
func extractCode(codings []codingEntry, system string) string {
	for _, c := range codings {
		if c.System == system {
			return c.Code
		}
	}
	return ""
}

func parseDateTime(s string) time.Time {
	for _, layout := range []string{time.RFC3339, "2006-01-02"} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.UTC()
		}
	}
	return time.Time{}
}
