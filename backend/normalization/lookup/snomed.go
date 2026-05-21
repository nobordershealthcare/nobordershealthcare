package lookup

// SNOMEDEntry describes a SNOMED CT concept used in the normalization pipeline.
// Currently covers allergy substances and common clinical disorders.
// If a SNOMED code is not in this table → return UnknownCode + ReviewFlag.
type SNOMEDEntry struct {
	Code        SNOMEDCode
	Display     string // English display term
	ConceptType string // "allergen" | "disorder" | "finding"
}

// LookupSNOMED returns the SNOMEDEntry for a code, or (zero, false) if unknown.
func LookupSNOMED(code SNOMEDCode) (SNOMEDEntry, bool) {
	e, ok := snomedByCode[code]
	return e, ok
}

// LookupSNOMEDByName resolves a substance/concept name to its SNOMED code.
// Returns (UnknownCode, false) if not found.
func LookupSNOMEDByName(name string) (SNOMEDCode, bool) {
	code, ok := snomedByName[normalize(name)]
	return code, ok
}

var (
	snomedByCode map[SNOMEDCode]SNOMEDEntry
	snomedByName map[string]SNOMEDCode
)

func init() {
	entries := []SNOMEDEntry{
		// ── Allergy substances (mandatory per spec) ───────────────────────────
		{Code: "764146007", Display: "Penicillin", ConceptType: "allergen"},
		{Code: "387207008", Display: "Ibuprofen", ConceptType: "allergen"},
		{Code: "372687004", Display: "Sulfonamides", ConceptType: "allergen"},
		{Code: "387458008", Display: "Aspirin", ConceptType: "allergen"},
		{Code: "1003754006", Display: "Latex", ConceptType: "allergen"},
		{Code: "762952008", Display: "Peanut", ConceptType: "allergen"},
		{Code: "409093005", Display: "Contrast media", ConceptType: "allergen"},
		// ── Additional common allergens ───────────────────────────────────────
		{Code: "256305009", Display: "Nuts", ConceptType: "allergen"},
		{Code: "256277009", Display: "Grass pollen", ConceptType: "allergen"},
		{Code: "57493009", Display: "Codeine", ConceptType: "allergen"},
		{Code: "372750000", Display: "Amoxicillin", ConceptType: "allergen"},
		{Code: "372687004", Display: "Trimethoprim-sulfamethoxazole", ConceptType: "allergen"},
		{Code: "373388000", Display: "Cephalosporin", ConceptType: "allergen"},
		{Code: "372687004", Display: "Sulfonamide antibiotic", ConceptType: "allergen"},
		// ── Clinical disorders ────────────────────────────────────────────────
		{Code: "46635009", Display: "Type 1 diabetes mellitus", ConceptType: "disorder"},
		{Code: "44054006", Display: "Type 2 diabetes mellitus", ConceptType: "disorder"},
		{Code: "73211009", Display: "Diabetes mellitus", ConceptType: "disorder"},
		{Code: "38341003", Display: "Hypertension", ConceptType: "disorder"},
		{Code: "53741008", Display: "Coronary arteriosclerosis", ConceptType: "disorder"},
		{Code: "84114007", Display: "Heart failure", ConceptType: "disorder"},
		{Code: "49436004", Display: "Atrial fibrillation", ConceptType: "disorder"},
		{Code: "230690007", Display: "Cerebrovascular accident", ConceptType: "disorder"},
		{Code: "195967001", Display: "Asthma", ConceptType: "disorder"},
		{Code: "13645005", Display: "Chronic obstructive pulmonary disease", ConceptType: "disorder"},
		{Code: "709044004", Display: "Chronic kidney disease", ConceptType: "disorder"},
		{Code: "40930008", Display: "Hypothyroidism", ConceptType: "disorder"},
		{Code: "34840004", Display: "Hyperthyroidism", ConceptType: "disorder"},
	}

	snomedByCode = make(map[SNOMEDCode]SNOMEDEntry, len(entries))
	snomedByName = make(map[string]SNOMEDCode, len(entries))

	for _, e := range entries {
		// Later entries with the same code overwrite earlier ones; both name
		// aliases are registered in snomedByName so either lookup succeeds.
		snomedByCode[e.Code] = e
		snomedByName[normalize(e.Display)] = e.Code
	}
}
