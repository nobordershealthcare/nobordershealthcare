// Local openEHR composition model.
// All identifiers are SHA3-256 hashes. No plain-text patient identifiers anywhere.
// Clinical codes: ICD-10, LOINC, SNOMED CT, ATC — never RxNorm.

import Foundation

// MARK: - openEHR archetypes (simplified for iOS wallet)

struct Composition: Sendable, Codable, Identifiable {
    let id: String                  // SHA3-256(userID + compositionUUID)
    let templateID: String          // e.g. "openEHR-EHR-COMPOSITION.health_summary.v1"
    let language: Language
    let territory: String           // ISO 3166-1 alpha-2
    let composer: String            // SHA3-256(userID)
    let dateCreated: Date
    var sections: [EHRSection]
    var sealedBlob: VaultManager.SealedVault?  // nil if not yet persisted
}

struct EHRSection: Sendable, Codable, Identifiable {
    let id: String
    let archetypeID: String         // e.g. "openEHR-EHR-SECTION.medication_summary.v1"
    let name: String
    var entries: [ClinicalEntry]
}

enum ClinicalEntry: Sendable, Codable {
    case medication(MedicationEntry)
    case allergy(AllergyEntry)
    case condition(ConditionEntry)
    case labResult(LabResultEntry)
    case vitalSign(VitalSignEntry)
}

// MARK: - Clinical entry types

struct MedicationEntry: Sendable, Codable, Identifiable {
    let id: String
    let atcCode: String             // ATC code — NEVER RxNorm (e.g. "C09AA03" for Lisinopril)
    let genericName: String
    let dose: DvQuantity
    let frequency: String
    let startDate: Date
    var endDate: Date?
}

struct AllergyEntry: Sendable, Codable, Identifiable {
    let id: String
    let snomedCode: String          // SNOMED CT concept ID
    let substanceName: String
    let severity: AllergySeverity
    let reaction: String            // SNOMED CT reaction term
    let onsetDate: Date?
}

struct ConditionEntry: Sendable, Codable, Identifiable {
    let id: String
    let icd10Code: String           // ICD-10-CM or ICD-10-GM
    let displayName: String
    let clinicalStatus: ClinicalStatus
    let onsetDate: Date?
}

struct LabResultEntry: Sendable, Codable, Identifiable {
    let id: String
    let loincCode: String           // LOINC code (e.g. "4548-4" for HbA1c)
    let displayName: String
    let value: DvQuantity
    let referenceRange: ReferenceRange?
    let observationDate: Date
}

struct VitalSignEntry: Sendable, Codable, Identifiable {
    let id: String
    let loincCode: String
    let displayName: String
    let value: DvQuantity
    let observationDate: Date
}

// MARK: - openEHR data types

struct DvQuantity: Sendable, Codable {
    let magnitude: Double
    let units: String               // UCUM units (e.g. "mmol/L", "mg", "mmHg")
    let precision: Int
}

struct ReferenceRange: Sendable, Codable {
    let low: Double
    let high: Double
    let units: String
}

struct Language: Sendable, Codable {
    let code: String                // ISO 639-1 (e.g. "en", "de", "pt")
    let terminologyID: String       // always "ISO_639-1"
}

enum AllergySeverity: String, Sendable, Codable {
    case mild, moderate, severe, fatal
}

enum ClinicalStatus: String, Sendable, Codable {
    case active, remission, resolved, inactive
}

// MARK: - IPS emergency subset

struct IPSEmergencySubset: Sendable, Codable {
    let patientHash: String         // SHA3-256(userID)
    let allergies: [AllergyEntry]
    let medications: [MedicationEntry]
    let conditions: [ConditionEntry]
    let bloodGroup: String?         // SNOMED code if known
    let generatedAt: Date
}
