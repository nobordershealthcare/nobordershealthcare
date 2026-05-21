package lookup

import "strings"

// ATCEntry is a single entry in the ATC lookup table.
type ATCEntry struct {
	Code      ATCCode
	Name      string // canonical English drug name
	ATCLevel3 string // 5-character ATC level-3 group (e.g. "C09AA")
	ClassDesc string // human-readable group description
}

// LookupATC resolves a drug name to its ATC code.
// Input is normalized (trimmed, lowercased) before lookup.
// Returns (UnknownCode, false) if not found — never guesses.
func LookupATC(drugName string) (ATCCode, bool) {
	code, ok := atcByName[normalize(drugName)]
	return code, ok
}

// ATCEntryByCode returns the full ATCEntry for a known code.
// Returns (zero, false) if the code is not in the table.
func ATCEntryByCode(code ATCCode) (ATCEntry, bool) {
	e, ok := atcByCode[code]
	return e, ok
}

func normalize(s string) string {
	return strings.ToLower(strings.TrimSpace(s))
}

// atcByName maps lowercase drug name → ATC code.
// atcByCode maps ATC code → full entry.
// Both are populated once in init() — zero allocation per lookup.
var (
	atcByName map[string]ATCCode
	atcByCode map[ATCCode]ATCEntry
)

func init() {
	entries := []ATCEntry{
		// ── Diabetes ─────────────────────────────────────────────────────────
		{Code: "A10BA02", Name: "Metformin", ATCLevel3: "A10BA", ClassDesc: "Biguanides"},
		{Code: "A10BB01", Name: "Glibenclamide", ATCLevel3: "A10BB", ClassDesc: "Sulfonylureas"},
		{Code: "A10BB09", Name: "Gliclazide", ATCLevel3: "A10BB", ClassDesc: "Sulfonylureas"},
		{Code: "A10BH01", Name: "Sitagliptin", ATCLevel3: "A10BH", ClassDesc: "DPP-4 inhibitors"},
		{Code: "A10BK01", Name: "Dapagliflozin", ATCLevel3: "A10BK", ClassDesc: "SGLT2 inhibitors"},
		{Code: "A10BK03", Name: "Empagliflozin", ATCLevel3: "A10BK", ClassDesc: "SGLT2 inhibitors"},
		{Code: "A10AE04", Name: "Insulin glargine", ATCLevel3: "A10AE", ClassDesc: "Insulins and analogues, long-acting"},
		{Code: "A10AB05", Name: "Insulin aspart", ATCLevel3: "A10AB", ClassDesc: "Insulins and analogues, fast-acting"},
		// ── Gastric acid ─────────────────────────────────────────────────────
		{Code: "A02BC01", Name: "Omeprazole", ATCLevel3: "A02BC", ClassDesc: "Proton pump inhibitors"},
		{Code: "A02BC02", Name: "Pantoprazole", ATCLevel3: "A02BC", ClassDesc: "Proton pump inhibitors"},
		{Code: "A02BC03", Name: "Lansoprazole", ATCLevel3: "A02BC", ClassDesc: "Proton pump inhibitors"},
		{Code: "A02BC04", Name: "Rabeprazole", ATCLevel3: "A02BC", ClassDesc: "Proton pump inhibitors"},
		{Code: "A02BC05", Name: "Esomeprazole", ATCLevel3: "A02BC", ClassDesc: "Proton pump inhibitors"},
		// ── ACE inhibitors ───────────────────────────────────────────────────
		{Code: "C09AA01", Name: "Captopril", ATCLevel3: "C09AA", ClassDesc: "ACE inhibitors, plain"},
		{Code: "C09AA02", Name: "Enalapril", ATCLevel3: "C09AA", ClassDesc: "ACE inhibitors, plain"},
		{Code: "C09AA03", Name: "Lisinopril", ATCLevel3: "C09AA", ClassDesc: "ACE inhibitors, plain"},
		{Code: "C09AA05", Name: "Ramipril", ATCLevel3: "C09AA", ClassDesc: "ACE inhibitors, plain"},
		// ── ARBs ─────────────────────────────────────────────────────────────
		{Code: "C09CA01", Name: "Losartan", ATCLevel3: "C09CA", ClassDesc: "Angiotensin II receptor blockers"},
		{Code: "C09CA03", Name: "Valsartan", ATCLevel3: "C09CA", ClassDesc: "Angiotensin II receptor blockers"},
		{Code: "C09CA04", Name: "Irbesartan", ATCLevel3: "C09CA", ClassDesc: "Angiotensin II receptor blockers"},
		{Code: "C09CA06", Name: "Candesartan", ATCLevel3: "C09CA", ClassDesc: "Angiotensin II receptor blockers"},
		{Code: "C09CA07", Name: "Telmisartan", ATCLevel3: "C09CA", ClassDesc: "Angiotensin II receptor blockers"},
		{Code: "C09CA08", Name: "Olmesartan", ATCLevel3: "C09CA", ClassDesc: "Angiotensin II receptor blockers"},
		// ── Calcium channel blockers ─────────────────────────────────────────
		{Code: "C08CA01", Name: "Amlodipine", ATCLevel3: "C08CA", ClassDesc: "Dihydropyridine calcium channel blockers"},
		{Code: "C08CA05", Name: "Nifedipine", ATCLevel3: "C08CA", ClassDesc: "Dihydropyridine calcium channel blockers"},
		// ── Beta blockers ────────────────────────────────────────────────────
		{Code: "C07AB02", Name: "Metoprolol", ATCLevel3: "C07AB", ClassDesc: "Selective beta blockers"},
		{Code: "C07AB03", Name: "Atenolol", ATCLevel3: "C07AB", ClassDesc: "Selective beta blockers"},
		{Code: "C07AB07", Name: "Bisoprolol", ATCLevel3: "C07AB", ClassDesc: "Selective beta blockers"},
		{Code: "C07AG02", Name: "Carvedilol", ATCLevel3: "C07AG", ClassDesc: "Alpha+beta blockers"},
		// ── Diuretics ────────────────────────────────────────────────────────
		{Code: "C03AA03", Name: "Hydrochlorothiazide", ATCLevel3: "C03AA", ClassDesc: "Thiazides"},
		{Code: "C03BA11", Name: "Indapamide", ATCLevel3: "C03BA", ClassDesc: "Thiazide-related diuretics"},
		{Code: "C03CA01", Name: "Furosemide", ATCLevel3: "C03CA", ClassDesc: "High-ceiling diuretics (loop)"},
		{Code: "C03DA01", Name: "Spironolactone", ATCLevel3: "C03DA", ClassDesc: "Aldosterone antagonists"},
		// ── Statins ──────────────────────────────────────────────────────────
		{Code: "C10AA01", Name: "Simvastatin", ATCLevel3: "C10AA", ClassDesc: "HMG CoA reductase inhibitors"},
		{Code: "C10AA03", Name: "Pravastatin", ATCLevel3: "C10AA", ClassDesc: "HMG CoA reductase inhibitors"},
		{Code: "C10AA05", Name: "Atorvastatin", ATCLevel3: "C10AA", ClassDesc: "HMG CoA reductase inhibitors"},
		{Code: "C10AA07", Name: "Rosuvastatin", ATCLevel3: "C10AA", ClassDesc: "HMG CoA reductase inhibitors"},
		// ── Cardiac glycosides / antithrombotics ─────────────────────────────
		{Code: "C01AA05", Name: "Digoxin", ATCLevel3: "C01AA", ClassDesc: "Cardiac glycosides"},
		{Code: "B01AA03", Name: "Warfarin", ATCLevel3: "B01AA", ClassDesc: "Vitamin K antagonists"},
		{Code: "B01AC04", Name: "Clopidogrel", ATCLevel3: "B01AC", ClassDesc: "Platelet aggregation inhibitors"},
		{Code: "B01AC06", Name: "Aspirin", ATCLevel3: "B01AC", ClassDesc: "Platelet aggregation inhibitors"},
		{Code: "B01AE07", Name: "Dabigatran", ATCLevel3: "B01AE", ClassDesc: "Direct thrombin inhibitors"},
		{Code: "B01AF01", Name: "Rivaroxaban", ATCLevel3: "B01AF", ClassDesc: "Direct factor Xa inhibitors"},
		{Code: "B01AF02", Name: "Apixaban", ATCLevel3: "B01AF", ClassDesc: "Direct factor Xa inhibitors"},
		// ── Thyroid / corticosteroids ─────────────────────────────────────────
		{Code: "H03AA01", Name: "Levothyroxine", ATCLevel3: "H03AA", ClassDesc: "Thyroid hormones"},
		{Code: "H02AB02", Name: "Dexamethasone", ATCLevel3: "H02AB", ClassDesc: "Glucocorticoids"},
		{Code: "H02AB06", Name: "Prednisolone", ATCLevel3: "H02AB", ClassDesc: "Glucocorticoids"},
		// ── Respiratory ──────────────────────────────────────────────────────
		{Code: "R03AC02", Name: "Salbutamol", ATCLevel3: "R03AC", ClassDesc: "Short-acting beta-2 agonists"},
		{Code: "R03AC12", Name: "Salmeterol", ATCLevel3: "R03AC", ClassDesc: "Long-acting beta-2 agonists"},
		{Code: "R03AC13", Name: "Formoterol", ATCLevel3: "R03AC", ClassDesc: "Long-acting beta-2 agonists"},
		{Code: "R03BA02", Name: "Budesonide", ATCLevel3: "R03BA", ClassDesc: "Inhaled glucocorticoids"},
		{Code: "R03BB04", Name: "Tiotropium", ATCLevel3: "R03BB", ClassDesc: "Anticholinergics for COPD"},
		// ── Analgesics / anti-inflammatory ───────────────────────────────────
		{Code: "N02BE01", Name: "Paracetamol", ATCLevel3: "N02BE", ClassDesc: "Anilides (paracetamol group)"},
		{Code: "M01AE01", Name: "Ibuprofen", ATCLevel3: "M01AE", ClassDesc: "Propionic acid derivatives (NSAIDs)"},
		{Code: "M01AE02", Name: "Naproxen", ATCLevel3: "M01AE", ClassDesc: "Propionic acid derivatives (NSAIDs)"},
		{Code: "M01AB05", Name: "Diclofenac", ATCLevel3: "M01AB", ClassDesc: "Acetic acid derivatives (NSAIDs)"},
		{Code: "M01AC06", Name: "Meloxicam", ATCLevel3: "M01AC", ClassDesc: "Oxicams (NSAIDs)"},
		{Code: "M01AH01", Name: "Celecoxib", ATCLevel3: "M01AH", ClassDesc: "COX-2 inhibitors"},
		{Code: "M04AA01", Name: "Allopurinol", ATCLevel3: "M04AA", ClassDesc: "Antigout preparations"},
		// ── Psychotropics / neuro ─────────────────────────────────────────────
		{Code: "N06AB03", Name: "Fluoxetine", ATCLevel3: "N06AB", ClassDesc: "SSRIs"},
		{Code: "N06AB06", Name: "Sertraline", ATCLevel3: "N06AB", ClassDesc: "SSRIs"},
		{Code: "N06AB10", Name: "Escitalopram", ATCLevel3: "N06AB", ClassDesc: "SSRIs"},
		{Code: "N06AA09", Name: "Amitriptyline", ATCLevel3: "N06AA", ClassDesc: "Non-selective monoamine reuptake inhibitors"},
		{Code: "N03AX12", Name: "Gabapentin", ATCLevel3: "N03AX", ClassDesc: "Antiepileptics, other"},
		{Code: "N03AX16", Name: "Pregabalin", ATCLevel3: "N03AX", ClassDesc: "Antiepileptics, other"},
		// ── Antibiotics / antifungals ─────────────────────────────────────────
		{Code: "J01CA04", Name: "Amoxicillin", ATCLevel3: "J01CA", ClassDesc: "Extended-spectrum penicillins"},
		{Code: "J01DB01", Name: "Cefalexin", ATCLevel3: "J01DB", ClassDesc: "First-generation cephalosporins"},
		{Code: "J01FA09", Name: "Clarithromycin", ATCLevel3: "J01FA", ClassDesc: "Macrolides"},
		{Code: "J01FA10", Name: "Azithromycin", ATCLevel3: "J01FA", ClassDesc: "Macrolides"},
		{Code: "J01MA02", Name: "Ciprofloxacin", ATCLevel3: "J01MA", ClassDesc: "Fluoroquinolones"},
		{Code: "J01AA02", Name: "Doxycycline", ATCLevel3: "J01AA", ClassDesc: "Tetracyclines"},
		{Code: "J01EA01", Name: "Trimethoprim", ATCLevel3: "J01EA", ClassDesc: "Trimethoprim and derivatives"},
		{Code: "P01AB01", Name: "Metronidazole", ATCLevel3: "P01AB", ClassDesc: "Nitroimidazole antiprotozoals"},
		{Code: "J02AC01", Name: "Fluconazole", ATCLevel3: "J02AC", ClassDesc: "Triazole antifungals"},
	}

	atcByName = make(map[string]ATCCode, len(entries)*2)
	atcByCode = make(map[ATCCode]ATCEntry, len(entries))

	for _, e := range entries {
		atcByCode[e.Code] = e
		atcByName[normalize(e.Name)] = e.Code
	}
}
