// Package i18n provides IPS (International Patient Summary) section label
// translations for all 24 EU official languages.
//
// LOINC and ATC codes are language-independent and never translated.
// Only the human-readable section headings in the IPS Composition are localised.
//
// Locale comes from the JWT "locale" claim (BCP-47 language tag).
// Unknown locales fall back to "en".
package i18n

// SectionLabels holds the display strings for the five mandatory IPS sections
// in a single language.
type SectionLabels struct {
	MedicationSummary       string
	AllergiesAndIntolerances string
	ProblemList             string
	Results                 string
	VitalSigns              string
}

// labelsMap holds translations keyed by BCP-47 language tag (2-char ISO 639-1).
var labelsMap = map[string]SectionLabels{
	"bg": {
		MedicationSummary:       "Списък с медикаменти",
		AllergiesAndIntolerances: "Алергии и непоносимости",
		ProblemList:             "Списък с диагнози",
		Results:                 "Резултати",
		VitalSigns:              "Жизнени показатели",
	},
	"cs": {
		MedicationSummary:       "Přehled léků",
		AllergiesAndIntolerances: "Alergie a intolerance",
		ProblemList:             "Seznam problémů",
		Results:                 "Výsledky",
		VitalSigns:              "Vitální funkce",
	},
	"da": {
		MedicationSummary:       "Medicationsoversigt",
		AllergiesAndIntolerances: "Allergier og intoleranser",
		ProblemList:             "Problemliste",
		Results:                 "Resultater",
		VitalSigns:              "Vitale parametre",
	},
	"de": {
		MedicationSummary:       "Medikamentenübersicht",
		AllergiesAndIntolerances: "Allergien und Unverträglichkeiten",
		ProblemList:             "Problemliste",
		Results:                 "Ergebnisse",
		VitalSigns:              "Vitalzeichen",
	},
	"el": {
		MedicationSummary:       "Φαρμακευτική αγωγή",
		AllergiesAndIntolerances: "Αλλεργίες και δυσανεξίες",
		ProblemList:             "Λίστα προβλημάτων",
		Results:                 "Αποτελέσματα",
		VitalSigns:              "Ζωτικά σημεία",
	},
	"en": {
		MedicationSummary:       "Medication Summary",
		AllergiesAndIntolerances: "Allergies and Intolerances",
		ProblemList:             "Problem List",
		Results:                 "Results",
		VitalSigns:              "Vital Signs",
	},
	"es": {
		MedicationSummary:       "Resumen de medicación",
		AllergiesAndIntolerances: "Alergias e intolerancias",
		ProblemList:             "Lista de problemas",
		Results:                 "Resultados",
		VitalSigns:              "Signos vitales",
	},
	"et": {
		MedicationSummary:       "Ravimite kokkuvõte",
		AllergiesAndIntolerances: "Allergilised reaktsioonid ja talumatus",
		ProblemList:             "Probleemide nimekiri",
		Results:                 "Tulemused",
		VitalSigns:              "Elutähtsad näitajad",
	},
	"fi": {
		MedicationSummary:       "Lääkitysyhteenveto",
		AllergiesAndIntolerances: "Allergiat ja intoleranssit",
		ProblemList:             "Ongelmalista",
		Results:                 "Tulokset",
		VitalSigns:              "Elintärkeät toiminnot",
	},
	"fr": {
		MedicationSummary:       "Résumé des médicaments",
		AllergiesAndIntolerances: "Allergies et intolérances",
		ProblemList:             "Liste des problèmes",
		Results:                 "Résultats",
		VitalSigns:              "Signes vitaux",
	},
	"ga": {
		MedicationSummary:       "Achoimre Cógas",
		AllergiesAndIntolerances: "Ailléirgí agus Aibhneoin",
		ProblemList:             "Liosta Fadhbanna",
		Results:                 "Torthaí",
		VitalSigns:              "Comharthaí Beatha",
	},
	"hr": {
		MedicationSummary:       "Pregled lijekova",
		AllergiesAndIntolerances: "Alergije i intolerancije",
		ProblemList:             "Popis problema",
		Results:                 "Rezultati",
		VitalSigns:              "Vitalni znakovi",
	},
	"hu": {
		MedicationSummary:       "Gyógyszerek összefoglalója",
		AllergiesAndIntolerances: "Allergiák és intoleranciák",
		ProblemList:             "Problémák listája",
		Results:                 "Eredmények",
		VitalSigns:              "Vitális funkciók",
	},
	"it": {
		MedicationSummary:       "Riepilogo delle terapie farmacologiche",
		AllergiesAndIntolerances: "Allergie e intolleranze",
		ProblemList:             "Lista dei problemi",
		Results:                 "Risultati",
		VitalSigns:              "Segni vitali",
	},
	"lt": {
		MedicationSummary:       "Vaistų santrauka",
		AllergiesAndIntolerances: "Alergijos ir netolerancija",
		ProblemList:             "Problemų sąrašas",
		Results:                 "Rezultatai",
		VitalSigns:              "Gyvybiniai požymiai",
	},
	"lv": {
		MedicationSummary:       "Medikamentu kopsavilkums",
		AllergiesAndIntolerances: "Alerģijas un nepanesība",
		ProblemList:             "Problēmu saraksts",
		Results:                 "Rezultāti",
		VitalSigns:              "Dzīvības rādītāji",
	},
	"mt": {
		MedicationSummary:       "Sommarju tal-Mediċini",
		AllergiesAndIntolerances: "Allerġiji u Intolleranzi",
		ProblemList:             "Lista tal-Problemi",
		Results:                 "Riżultati",
		VitalSigns:              "Sinjali Vitali",
	},
	"nl": {
		MedicationSummary:       "Medicatieoverzicht",
		AllergiesAndIntolerances: "Allergieën en intoleranties",
		ProblemList:             "Probleemlijst",
		Results:                 "Resultaten",
		VitalSigns:              "Vitale parameters",
	},
	"pl": {
		MedicationSummary:       "Podsumowanie leków",
		AllergiesAndIntolerances: "Alergie i nietolerancje",
		ProblemList:             "Lista problemów",
		Results:                 "Wyniki",
		VitalSigns:              "Parametry życiowe",
	},
	"pt": {
		MedicationSummary:       "Resumo de medicamentos",
		AllergiesAndIntolerances: "Alergias e intolerâncias",
		ProblemList:             "Lista de problemas",
		Results:                 "Resultados",
		VitalSigns:              "Sinais vitais",
	},
	"ro": {
		MedicationSummary:       "Rezumatul medicamentelor",
		AllergiesAndIntolerances: "Alergii și intoleranțe",
		ProblemList:             "Lista problemelor",
		Results:                 "Rezultate",
		VitalSigns:              "Semne vitale",
	},
	"sk": {
		MedicationSummary:       "Prehľad liekov",
		AllergiesAndIntolerances: "Alergie a intolerancie",
		ProblemList:             "Zoznam problémov",
		Results:                 "Výsledky",
		VitalSigns:              "Vitálne funkcie",
	},
	"sl": {
		MedicationSummary:       "Pregled zdravil",
		AllergiesAndIntolerances: "Alergije in intolerance",
		ProblemList:             "Seznam težav",
		Results:                 "Rezultati",
		VitalSigns:              "Vitalni znaki",
	},
	"sv": {
		MedicationSummary:       "Läkemedelsöversikt",
		AllergiesAndIntolerances: "Allergier och intoleranser",
		ProblemList:             "Problemlista",
		Results:                 "Resultat",
		VitalSigns:              "Vitalparametrar",
	},
}

// ForLocale returns the SectionLabels for the given BCP-47 locale tag.
// Unknown or empty locales fall back to English ("en").
// Only the primary language subtag is used ("pt-BR" → "pt").
func ForLocale(locale string) SectionLabels {
	tag := primaryTag(locale)
	if labels, ok := labelsMap[tag]; ok {
		return labels
	}
	return labelsMap["en"]
}

// primaryTag extracts the primary language subtag from a BCP-47 tag.
// "pt-BR" → "pt", "de-AT" → "de", "en" → "en".
func primaryTag(locale string) string {
	for i, r := range locale {
		if r == '-' || r == '_' {
			return locale[:i]
		}
	}
	return locale
}
