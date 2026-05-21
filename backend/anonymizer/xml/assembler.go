package xml

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"time"
)

// Role constants mirror the smart-contract access roles defined in contracts/.
type Role string

const (
	RolePatient    Role = "patient"
	RoleGuardian   Role = "guardian"
	RoleERDoctor   Role = "er_doctor"
	RoleInsurer    Role = "insurer"
	RoleResearcher Role = "researcher"
	RoleAdmin      Role = "admin"
)

// ClinicalRecord is the in-memory representation of a decrypted health blob,
// already parsed from the ScyllaDB payload. Fields use ICD-10, LOINC, SNOMED,
// and ATC codes — never RxNorm (EU-facing only).
type ClinicalRecord struct {
	PatientHashID string        // SHA3-256(userID) — never the real ID
	Diagnoses     []Diagnosis
	LabValues     []LabValue
	Medications   []Medication
}

type Diagnosis struct {
	ICD10Code   string // ICD-10-CM or ICD-10-GM
	SNOMEDCode  string // SNOMED CT concept ID
	Description string // clinical description, not patient name
}

type LabValue struct {
	LOINCCode string // e.g. "4548-4" for HbA1c
	Value     float64
	Unit      string
	Timestamp time.Time
}

type Medication struct {
	ATCCode string // e.g. "C09AA03" for Lisinopril — NEVER RxNorm
	Name    string
	Dose    string
}

// Assemble builds a scope-filtered openEHR / IPS XML document in memory.
// No intermediate bytes are written to disk.
// The returned []byte is the complete XML — caller is responsible for zeroing
// after use if it contains sensitive data.
func Assemble(record *ClinicalRecord, role Role) ([]byte, error) {
	filtered := filter(record, role)

	doc := buildIPSXML(filtered, role)

	var buf bytes.Buffer
	buf.WriteString(xml.Header)
	enc := xml.NewEncoder(&buf)
	enc.Indent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return nil, fmt.Errorf("xml encode: %w", err)
	}
	if err := enc.Flush(); err != nil {
		return nil, fmt.Errorf("xml flush: %w", err)
	}
	return buf.Bytes(), nil
}

// filter returns a ClinicalRecord containing only the fields the given role
// is permitted to see, per the smart-contract access matrix.
func filter(r *ClinicalRecord, role Role) *ClinicalRecord {
	out := &ClinicalRecord{PatientHashID: r.PatientHashID}

	switch role {
	case RolePatient, RoleGuardian, RoleAdmin:
		// Full record.
		out.Diagnoses = r.Diagnoses
		out.LabValues = r.LabValues
		out.Medications = r.Medications

	case RoleERDoctor:
		// IPS emergency subset: diagnoses + medications only.
		out.Diagnoses = r.Diagnoses
		out.Medications = r.Medications

	case RoleInsurer:
		// Claim-relevant: diagnoses only.
		out.Diagnoses = r.Diagnoses

	case RoleResearcher:
		// Anonymised aggregate: lab values only, no patient hash.
		out.PatientHashID = ""
		out.LabValues = r.LabValues
	}

	return out
}

// ipsDocument is the XML root for an IPS (International Patient Summary) document.
type ipsDocument struct {
	XMLName    xml.Name    `xml:"ClinicalDocument"`
	XMLNS      string      `xml:"xmlns,attr"`
	TemplateID string      `xml:"templateId>root,attr"`
	Role       string      `xml:"accessRole"`
	Patient    ipsPatient  `xml:"recordTarget>patientRole"`
	Body       ipsBody     `xml:"component>structuredBody"`
}

type ipsPatient struct {
	ID string `xml:"id,attr,omitempty"`
}

type ipsBody struct {
	Diagnoses   []ipsDiagnosis   `xml:"section>diagnoses>entry,omitempty"`
	LabValues   []ipsLabValue    `xml:"section>labValues>entry,omitempty"`
	Medications []ipsMedication  `xml:"section>medications>entry,omitempty"`
}

type ipsDiagnosis struct {
	ICD10  string `xml:"icd10"`
	SNOMED string `xml:"snomed"`
	Text   string `xml:"text"`
}

type ipsLabValue struct {
	LOINC string  `xml:"loinc"`
	Value float64 `xml:"value"`
	Unit  string  `xml:"unit"`
	Time  string  `xml:"effectiveTime"`
}

type ipsMedication struct {
	ATC  string `xml:"atc"`
	Name string `xml:"name"`
	Dose string `xml:"dose"`
}

func buildIPSXML(r *ClinicalRecord, role Role) ipsDocument {
	doc := ipsDocument{
		XMLNS:      "urn:hl7-org:v3",
		TemplateID: "2.16.840.1.113883.10.22.1.1",
		Role:       string(role),
		Patient:    ipsPatient{ID: r.PatientHashID},
	}

	for _, d := range r.Diagnoses {
		doc.Body.Diagnoses = append(doc.Body.Diagnoses, ipsDiagnosis{
			ICD10:  d.ICD10Code,
			SNOMED: d.SNOMEDCode,
			Text:   d.Description,
		})
	}
	for _, l := range r.LabValues {
		doc.Body.LabValues = append(doc.Body.LabValues, ipsLabValue{
			LOINC: l.LOINCCode,
			Value: l.Value,
			Unit:  l.Unit,
			Time:  l.Timestamp.UTC().Format(time.RFC3339),
		})
	}
	for _, m := range r.Medications {
		doc.Body.Medications = append(doc.Body.Medications, ipsMedication{
			ATC:  m.ATCCode, // ATC codes only — never RxNorm for EU-facing output
			Name: m.Name,
			Dose: m.Dose,
		})
	}

	return doc
}
