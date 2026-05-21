package lookup

import "regexp"

// icd10Pattern matches valid ICD-10-CM/GM codes:
//
//	Letter + 2 digits, optionally followed by a dot and up to 4 alphanumeric chars.
//	Examples: "E11", "E11.9", "I10", "J06.9", "Z87.39"
var icd10Pattern = regexp.MustCompile(`^[A-Z][0-9]{2}(\.[0-9A-Z]{1,4})?$`)

// ICD10Entry is a known ICD-10 code with its canonical display name.
type ICD10Entry struct {
	Code    ICD10Code
	Display string // English description
}

// ValidateICD10Format returns true if the code matches the ICD-10 format regex.
// This is a format check only — it does NOT confirm the code exists in any release.
func ValidateICD10Format(code ICD10Code) bool {
	return icd10Pattern.MatchString(string(code))
}

// LookupICD10 returns a known ICD10Entry or (zero, false) if unrecognised.
// Unknown but format-valid codes → return UnknownCode + ReviewFlag.
// Invalid format codes → caller should reject them before reaching this function.
func LookupICD10(code ICD10Code) (ICD10Entry, bool) {
	e, ok := icd10ByCode[code]
	return e, ok
}

var icd10ByCode map[ICD10Code]ICD10Entry

func init() {
	entries := []ICD10Entry{
		// ── Endocrine / metabolic ─────────────────────────────────────────────
		{Code: "E10", Display: "Type 1 diabetes mellitus"},
		{Code: "E10.9", Display: "Type 1 diabetes mellitus without complications"},
		{Code: "E11", Display: "Type 2 diabetes mellitus"},
		{Code: "E11.9", Display: "Type 2 diabetes mellitus without complications"},
		{Code: "E11.65", Display: "Type 2 diabetes mellitus with hyperglycaemia"},
		{Code: "E78.5", Display: "Hyperlipidaemia, unspecified"},
		{Code: "E78.00", Display: "Pure hypercholesterolaemia, unspecified"},
		{Code: "E03.9", Display: "Hypothyroidism, unspecified"},
		{Code: "E05.9", Display: "Thyrotoxicosis, unspecified"},
		// ── Cardiovascular ────────────────────────────────────────────────────
		{Code: "I10", Display: "Essential (primary) hypertension"},
		{Code: "I25.10", Display: "Atherosclerotic heart disease of native coronary artery without angina pectoris"},
		{Code: "I50.9", Display: "Heart failure, unspecified"},
		{Code: "I48.91", Display: "Unspecified atrial fibrillation"},
		{Code: "I63.9", Display: "Cerebral infarction, unspecified"},
		{Code: "I21.9", Display: "Acute myocardial infarction, unspecified"},
		// ── Respiratory ──────────────────────────────────────────────────────
		{Code: "J45.909", Display: "Unspecified asthma, uncomplicated"},
		{Code: "J44.1", Display: "Chronic obstructive pulmonary disease with (acute) exacerbation"},
		{Code: "J44.0", Display: "Chronic obstructive pulmonary disease with acute lower respiratory infection"},
		{Code: "J06.9", Display: "Acute upper respiratory infection, unspecified"},
		// ── Renal ────────────────────────────────────────────────────────────
		{Code: "N18.3", Display: "Chronic kidney disease, stage 3"},
		{Code: "N18.4", Display: "Chronic kidney disease, stage 4"},
		{Code: "N18.5", Display: "Chronic kidney disease, stage 5"},
		{Code: "N18.9", Display: "Chronic kidney disease, unspecified"},
		// ── Musculoskeletal ───────────────────────────────────────────────────
		{Code: "M10.9", Display: "Gout, unspecified"},
		{Code: "M79.3", Display: "Panniculitis, unspecified"},
		// ── Mental health ─────────────────────────────────────────────────────
		{Code: "F32.9", Display: "Major depressive disorder, single episode, unspecified"},
		{Code: "F41.1", Display: "Generalized anxiety disorder"},
		// ── Allergy / immunology ──────────────────────────────────────────────
		{Code: "Z88.0", Display: "Allergy status to penicillin"},
		{Code: "Z88.1", Display: "Allergy status to other antibiotic agents"},
		{Code: "Z88.6", Display: "Allergy status to analgesic agent"},
	}

	icd10ByCode = make(map[ICD10Code]ICD10Entry, len(entries))
	for _, e := range entries {
		icd10ByCode[e.Code] = e
	}
}
