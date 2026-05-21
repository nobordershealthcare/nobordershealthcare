// Static lookup tables for LOINC, SNOMED CT, ATC, and ICD-10 display labels (English).
// The English label from this file is the ONLY thing passed to xLMEngine for translation.
// xLMEngine never receives raw clinical codes, structured data, or patient content.

import Foundation

enum TerminologyMapper {

    // MARK: - LOINC

    static func loinc(code: String) -> String {
        loincTable[code] ?? code  // fall back to the code itself if unmapped
    }

    // High-frequency lab + vital codes. Extend as needed — never auto-generate via AI.
    private static let loincTable: [String: String] = [
        "4548-4":  "Glycated haemoglobin A1c",
        "2823-3":  "Potassium",
        "2951-2":  "Sodium",
        "2075-0":  "Chloride",
        "2160-0":  "Creatinine",
        "1751-7":  "Albumin",
        "3094-0":  "Urea nitrogen",
        "1742-6":  "Alanine aminotransferase",
        "1920-8":  "Aspartate aminotransferase",
        "6768-6":  "Alkaline phosphatase",
        "1975-2":  "Bilirubin total",
        "2885-2":  "Protein total",
        "789-8":   "Erythrocytes",
        "6690-2":  "Leucocytes",
        "777-3":   "Platelets",
        "718-7":   "Haemoglobin",
        "4544-3":  "Haematocrit",
        "59408-5": "Oxygen saturation pulse oximetry",
        "8867-4":  "Heart rate",
        "55284-4": "Blood pressure panel",
        "8480-6":  "Systolic blood pressure",
        "8462-4":  "Diastolic blood pressure",
        "8310-5":  "Body temperature",
        "9279-1":  "Respiratory rate",
        "29463-7": "Body weight",
        "8302-2":  "Body height",
        "39156-5": "Body mass index",
        "88040-1": "eGFR (CKD-EPI)",
        "33959-8": "Procalcitonin",
        "1988-5":  "C-reactive protein",
        "3255-7":  "Fibrinogen",
        "3173-2":  "APTT",
        "5902-2":  "Prothrombin time",
        "2276-4":  "Ferritin",
        "2498-4":  "Iron",
        "14749-6": "Glucose",
    ]

    // MARK: - ATC (medications)

    static func atc(code: String) -> String {
        atcTable[code] ?? code
    }

    private static let atcTable: [String: String] = [
        "C09AA03": "Lisinopril",
        "C09AA05": "Ramipril",
        "C09CA01": "Losartan",
        "C09CA04": "Irbesartan",
        "A10BA02": "Metformin",
        "A10AB01": "Insulin (short-acting)",
        "A10AE04": "Glargine insulin",
        "C10AA01": "Simvastatin",
        "C10AA05": "Atorvastatin",
        "C10AA07": "Rosuvastatin",
        "B01AC06": "Acetylsalicylic acid",
        "B01AF01": "Rivaroxaban",
        "B01AF02": "Apixaban",
        "B01AA03": "Warfarin",
        "C07AB02": "Metoprolol",
        "C07AB07": "Bisoprolol",
        "C03CA01": "Furosemide",
        "C08CA01": "Amlodipine",
        "N02BE01": "Paracetamol",
        "N02AA01": "Morphine",
        "N05BA01": "Diazepam",
        "R03AC02": "Salbutamol",
        "R03BA02": "Budesonide",
        "J01CA04": "Amoxicillin",
        "J01CR02": "Amoxicillin + clavulanate",
        "J01FA09": "Clarithromycin",
        "A02BC01": "Omeprazole",
        "A02BC05": "Esomeprazole",
        "H03AA01": "Levothyroxine",
        "N06AB06": "Sertraline",
        "N06AB04": "Citalopram",
    ]

    // MARK: - SNOMED CT (selected allergy substances)

    static func snomed(code: String) -> String {
        snomedTable[code] ?? code
    }

    private static let snomedTable: [String: String] = [
        "372687004": "Amoxicillin",
        "373270004": "Penicillin",
        "372741007": "Sulfonamide",
        "413427002": "Latex",
        "256259004": "Pollen",
        "84489001":  "Milk protein",
        "102263004": "Egg protein",
        "260147004": "Peanut",
        "226793009": "Shellfish",
        "303300008": "Bee venom",
        "373252002": "Aspirin",
        "387205003": "Ibuprofen",
        "387540000": "Codeine",
        "373303003": "Metformin",
    ]

    // MARK: - ICD-10

    static func icd10(code: String) -> String {
        icd10Table[code] ?? code
    }

    private static let icd10Table: [String: String] = [
        "E11":   "Type 2 diabetes mellitus",
        "E10":   "Type 1 diabetes mellitus",
        "I10":   "Essential (primary) hypertension",
        "I25.1": "Atherosclerotic heart disease",
        "I50.9": "Heart failure, unspecified",
        "J45":   "Asthma",
        "J44.1": "COPD, acute exacerbation",
        "N18":   "Chronic kidney disease",
        "K21.0": "Gastro-oesophageal reflux disease",
        "F32":   "Depressive episode",
        "F41.1": "Generalised anxiety disorder",
        "M79.3": "Panniculitis",
        "G20":   "Parkinson disease",
        "G30":   "Alzheimer disease",
        "C50":   "Malignant neoplasm of breast",
    ]

    // MARK: - Generic label lookup (entry point for xLMEngine)

    enum TerminologySystem {
        case loinc, atc, snomed, icd10
    }

    // Returns the canonical English label. xLMEngine may translate this string.
    static func englishLabel(code: String, system: TerminologySystem) -> String {
        switch system {
        case .loinc:  return loinc(code: code)
        case .atc:    return atc(code: code)
        case .snomed: return snomed(code: code)
        case .icd10:  return icd10(code: code)
        }
    }
}
