package lookup

// LOINCEntry describes a single LOINC observation code.
type LOINCEntry struct {
	Code       LOINCCode
	ShortName  string // brief label used in UI and IPS section display
	LongName   string // full LOINC long common name
	UCUMUnit   string // canonical UCUM unit string
	System     string // "Blood", "Serum/Plasma", "Urine", "VitalSign"
	Category   string // FHIR observation-category: "laboratory" or "vital-signs"
}

// LookupLOINC returns the LOINCEntry for a code, or (zero, false) if unknown.
// Callers must treat an unknown code as UnknownCode + ReviewFlag.
func LookupLOINC(code LOINCCode) (LOINCEntry, bool) {
	e, ok := loincByCode[code]
	return e, ok
}

var loincByCode map[LOINCCode]LOINCEntry

func init() {
	entries := []LOINCEntry{
		// ── Glycaemia ────────────────────────────────────────────────────────
		{
			Code: "4548-4", ShortName: "HbA1c",
			LongName: "Hemoglobin A1c/Hemoglobin.total in Blood",
			UCUMUnit: "%", System: "Blood", Category: "laboratory",
		},
		{
			Code: "1558-6", ShortName: "Glucose fasting",
			LongName: "Fasting glucose [Mass/volume] in Serum or Plasma",
			UCUMUnit: "mg/dL", System: "Serum/Plasma", Category: "laboratory",
		},
		// ── Renal ────────────────────────────────────────────────────────────
		{
			Code: "2160-0", ShortName: "Creatinine",
			LongName: "Creatinine [Mass/volume] in Serum or Plasma",
			UCUMUnit: "mg/dL", System: "Serum/Plasma", Category: "laboratory",
		},
		{
			Code: "62238-1", ShortName: "eGFR",
			LongName: "Glomerular filtration rate/1.73 sq M.predicted [Volume Rate/Area] in Serum, Plasma or Blood by Creatinine-based formula (CKD-EPI)",
			UCUMUnit: "mL/min/{1.73_m2}", System: "Serum/Plasma", Category: "laboratory",
		},
		{
			Code: "3094-0", ShortName: "BUN",
			LongName: "Urea nitrogen [Mass/volume] in Serum or Plasma",
			UCUMUnit: "mg/dL", System: "Serum/Plasma", Category: "laboratory",
		},
		// ── Lipids ───────────────────────────────────────────────────────────
		{
			Code: "2093-3", ShortName: "Cholesterol",
			LongName: "Cholesterol [Mass/volume] in Serum or Plasma",
			UCUMUnit: "mg/dL", System: "Serum/Plasma", Category: "laboratory",
		},
		{
			Code: "2089-1", ShortName: "LDL cholesterol",
			LongName: "Low density lipoprotein cholesterol [Mass/volume] in Serum or Plasma",
			UCUMUnit: "mg/dL", System: "Serum/Plasma", Category: "laboratory",
		},
		{
			Code: "2085-9", ShortName: "HDL cholesterol",
			LongName: "High density lipoprotein cholesterol [Mass/volume] in Serum or Plasma",
			UCUMUnit: "mg/dL", System: "Serum/Plasma", Category: "laboratory",
		},
		{
			Code: "2571-8", ShortName: "Triglycerides",
			LongName: "Triglycerides [Mass/volume] in Serum or Plasma",
			UCUMUnit: "mg/dL", System: "Serum/Plasma", Category: "laboratory",
		},
		// ── Vital signs ──────────────────────────────────────────────────────
		{
			Code: "8480-6", ShortName: "BP systolic",
			LongName: "Systolic blood pressure",
			UCUMUnit: "mm[Hg]", System: "VitalSign", Category: "vital-signs",
		},
		{
			Code: "8462-4", ShortName: "BP diastolic",
			LongName: "Diastolic blood pressure",
			UCUMUnit: "mm[Hg]", System: "VitalSign", Category: "vital-signs",
		},
		// ── Haematology ──────────────────────────────────────────────────────
		{
			Code: "718-7", ShortName: "Hemoglobin",
			LongName: "Hemoglobin [Mass/volume] in Blood",
			UCUMUnit: "g/dL", System: "Blood", Category: "laboratory",
		},
		{
			Code: "6690-2", ShortName: "Leukocytes",
			LongName: "Leukocytes [#/volume] in Blood by Automated count",
			UCUMUnit: "10*3/uL", System: "Blood", Category: "laboratory",
		},
		{
			Code: "777-3", ShortName: "Platelets",
			LongName: "Platelets [#/volume] in Blood by Automated count",
			UCUMUnit: "10*3/uL", System: "Blood", Category: "laboratory",
		},
		// ── Liver ────────────────────────────────────────────────────────────
		{
			Code: "1742-6", ShortName: "ALT",
			LongName: "Alanine aminotransferase [Enzymatic activity/volume] in Serum or Plasma",
			UCUMUnit: "U/L", System: "Serum/Plasma", Category: "laboratory",
		},
		{
			Code: "1920-8", ShortName: "AST",
			LongName: "Aspartate aminotransferase [Enzymatic activity/volume] in Serum or Plasma",
			UCUMUnit: "U/L", System: "Serum/Plasma", Category: "laboratory",
		},
		// ── Thyroid ──────────────────────────────────────────────────────────
		{
			Code: "3016-3", ShortName: "TSH",
			LongName: "Thyrotropin [Units/volume] in Serum or Plasma",
			UCUMUnit: "mIU/L", System: "Serum/Plasma", Category: "laboratory",
		},
		// ── Electrolytes ─────────────────────────────────────────────────────
		{
			Code: "2951-2", ShortName: "Sodium",
			LongName: "Sodium [Moles/volume] in Serum or Plasma",
			UCUMUnit: "mmol/L", System: "Serum/Plasma", Category: "laboratory",
		},
		{
			Code: "2823-3", ShortName: "Potassium",
			LongName: "Potassium [Moles/volume] in Serum or Plasma",
			UCUMUnit: "mmol/L", System: "Serum/Plasma", Category: "laboratory",
		},
		// ── Inflammation ─────────────────────────────────────────────────────
		{
			Code: "1988-5", ShortName: "CRP",
			LongName: "C reactive protein [Mass/volume] in Serum or Plasma",
			UCUMUnit: "mg/L", System: "Serum/Plasma", Category: "laboratory",
		},
	}

	loincByCode = make(map[LOINCCode]LOINCEntry, len(entries))
	for _, e := range entries {
		loincByCode[e.Code] = e
	}
}
