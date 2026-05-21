// Maps local openEHR data model → FHIR R4 resources for API transport.
// Clinical codes pass through as-is — xLMEngine is NEVER called here.
// Patient references use SHA3-256(userID) as the logical ID.

import Foundation

// MARK: - Minimal FHIR R4 resource types

struct FHIRBundle: Sendable, Codable {
    let resourceType: String            // always "Bundle"
    let id: String
    let type: FHIRBundleType
    let timestamp: Date
    var entry: [FHIRBundleEntry]
}

enum FHIRBundleType: String, Sendable, Codable {
    case document, collection, transaction, searchset
}

struct FHIRBundleEntry: Sendable, Codable {
    let fullURL: String
    let resource: FHIRResource
}

// Using an enum to avoid existential boxing while keeping type-safe access
enum FHIRResource: Sendable, Codable {
    case patient(FHIRPatient)
    case allergyIntolerance(FHIRAllergyIntolerance)
    case medicationStatement(FHIRMedicationStatement)
    case condition(FHIRCondition)
    case observation(FHIRObservation)
    case composition(FHIRComposition)
}

struct FHIRPatient: Sendable, Codable {
    let resourceType = "Patient"
    let id: String                      // SHA3-256(userID) — no real name
    let active: Bool
    let identifier: [FHIRIdentifier]
}

struct FHIRAllergyIntolerance: Sendable, Codable {
    let resourceType = "AllergyIntolerance"
    let id: String
    let clinicalStatus: FHIRCodeableConcept
    let code: FHIRCodeableConcept       // SNOMED CT
    let patient: FHIRReference
    let onsetDateTime: Date?
    let reaction: [FHIRAllergyReaction]?
}

struct FHIRMedicationStatement: Sendable, Codable {
    let resourceType = "MedicationStatement"
    let id: String
    let status: String
    let medicationCodeableConcept: FHIRCodeableConcept  // ATC code
    let subject: FHIRReference
    let effectivePeriod: FHIRPeriod?
    let dosage: [FHIRDosage]?
}

struct FHIRCondition: Sendable, Codable {
    let resourceType = "Condition"
    let id: String
    let clinicalStatus: FHIRCodeableConcept
    let code: FHIRCodeableConcept       // ICD-10
    let subject: FHIRReference
    let onsetDateTime: Date?
}

struct FHIRObservation: Sendable, Codable {
    let resourceType = "Observation"
    let id: String
    let status: String
    let code: FHIRCodeableConcept       // LOINC
    let subject: FHIRReference
    let effectiveDateTime: Date
    let valueQuantity: FHIRQuantity?
    let referenceRange: [FHIRReferenceRange]?
}

struct FHIRComposition: Sendable, Codable {
    let resourceType = "Composition"
    let id: String
    let status: String
    let type: FHIRCodeableConcept
    let subject: FHIRReference
    let date: Date
    let author: [FHIRReference]
    let title: String
    var section: [FHIRSection]
}

// MARK: - FHIR primitives

struct FHIRCodeableConcept: Sendable, Codable {
    let coding: [FHIRCoding]
    let text: String?
}

struct FHIRCoding: Sendable, Codable {
    let system: String
    let code: String
    let display: String?
}

struct FHIRReference: Sendable, Codable {
    let reference: String           // e.g. "Patient/<sha3hex>"
}

struct FHIRIdentifier: Sendable, Codable {
    let system: String
    let value: String
}

struct FHIRPeriod: Sendable, Codable {
    let start: Date?
    let end: Date?
}

struct FHIRDosage: Sendable, Codable {
    let text: String?
    let doseAndRate: [FHIRDoseAndRate]?
}

struct FHIRDoseAndRate: Sendable, Codable {
    let doseQuantity: FHIRQuantity?
}

struct FHIRQuantity: Sendable, Codable {
    let value: Double
    let unit: String
    let system: String              // always "http://unitsofmeasure.org" (UCUM)
    let code: String
}

struct FHIRReferenceRange: Sendable, Codable {
    let low: FHIRQuantity?
    let high: FHIRQuantity?
}

struct FHIRAllergyReaction: Sendable, Codable {
    let manifestation: [FHIRCodeableConcept]
    let severity: String?
}

struct FHIRSection: Sendable, Codable {
    let title: String
    let code: FHIRCodeableConcept
    var entry: [FHIRReference]
}

// MARK: - Mapper

enum FHIRMapper {

    static func bundle(from composition: Composition, patientHash: String) -> FHIRBundle {
        var entries: [FHIRBundleEntry] = []
        let patientRef = FHIRReference(reference: "Patient/\(patientHash)")

        entries.append(FHIRBundleEntry(
            fullURL: "urn:uuid:\(composition.id)",
            resource: .patient(FHIRPatient(
                id: patientHash,
                active: true,
                identifier: [FHIRIdentifier(system: "urn:ietf:rfc:3986", value: "did:noborders:\(patientHash)")]
            ))
        ))

        for section in composition.sections {
            for entry in section.entries {
                if let entry = fhirEntry(from: entry, patientRef: patientRef) {
                    entries.append(entry)
                }
            }
        }

        return FHIRBundle(
            resourceType: "Bundle",
            id: composition.id,
            type: .document,
            timestamp: composition.dateCreated,
            entry: entries
        )
    }

    private static func fhirEntry(from entry: ClinicalEntry, patientRef: FHIRReference) -> FHIRBundleEntry? {
        switch entry {
        case .allergy(let a):
            return FHIRBundleEntry(fullURL: "urn:uuid:\(a.id)", resource: .allergyIntolerance(map(a, patient: patientRef)))
        case .medication(let m):
            return FHIRBundleEntry(fullURL: "urn:uuid:\(m.id)", resource: .medicationStatement(map(m, patient: patientRef)))
        case .condition(let c):
            return FHIRBundleEntry(fullURL: "urn:uuid:\(c.id)", resource: .condition(map(c, patient: patientRef)))
        case .labResult(let l):
            return FHIRBundleEntry(fullURL: "urn:uuid:\(l.id)", resource: .observation(mapLab(l, patient: patientRef)))
        case .vitalSign(let v):
            return FHIRBundleEntry(fullURL: "urn:uuid:\(v.id)", resource: .observation(mapVital(v, patient: patientRef)))
        }
    }

    private static func map(_ a: AllergyEntry, patient: FHIRReference) -> FHIRAllergyIntolerance {
        FHIRAllergyIntolerance(
            id: a.id,
            clinicalStatus: snomedStatus("active"),
            code: FHIRCodeableConcept(
                coding: [FHIRCoding(system: "http://snomed.info/sct", code: a.snomedCode, display: a.substanceName)],
                text: a.substanceName
            ),
            patient: patient,
            onsetDateTime: a.onsetDate,
            reaction: [FHIRAllergyReaction(
                manifestation: [FHIRCodeableConcept(
                    coding: [FHIRCoding(system: "http://snomed.info/sct", code: a.snomedCode, display: a.reaction)],
                    text: a.reaction
                )],
                severity: a.severity.rawValue
            )]
        )
    }

    private static func map(_ m: MedicationEntry, patient: FHIRReference) -> FHIRMedicationStatement {
        FHIRMedicationStatement(
            id: m.id,
            status: "active",
            medicationCodeableConcept: FHIRCodeableConcept(
                coding: [FHIRCoding(system: "http://www.whocc.no/atc", code: m.atcCode, display: m.genericName)],
                text: m.genericName
            ),
            subject: patient,
            effectivePeriod: FHIRPeriod(start: m.startDate, end: m.endDate),
            dosage: [FHIRDosage(text: m.frequency, doseAndRate: [
                FHIRDoseAndRate(doseQuantity: FHIRQuantity(
                    value: m.dose.magnitude,
                    unit: m.dose.units,
                    system: "http://unitsofmeasure.org",
                    code: m.dose.units
                ))
            ])]
        )
    }

    private static func map(_ c: ConditionEntry, patient: FHIRReference) -> FHIRCondition {
        FHIRCondition(
            id: c.id,
            clinicalStatus: snomedStatus(c.clinicalStatus.rawValue),
            code: FHIRCodeableConcept(
                coding: [FHIRCoding(system: "http://hl7.org/fhir/sid/icd-10", code: c.icd10Code, display: c.displayName)],
                text: c.displayName
            ),
            subject: patient,
            onsetDateTime: c.onsetDate
        )
    }

    private static func mapLab(_ l: LabResultEntry, patient: FHIRReference) -> FHIRObservation {
        FHIRObservation(
            id: l.id,
            status: "final",
            code: FHIRCodeableConcept(
                coding: [FHIRCoding(system: "http://loinc.org", code: l.loincCode, display: l.displayName)],
                text: l.displayName
            ),
            subject: patient,
            effectiveDateTime: l.observationDate,
            valueQuantity: FHIRQuantity(
                value: l.value.magnitude,
                unit: l.value.units,
                system: "http://unitsofmeasure.org",
                code: l.value.units
            ),
            referenceRange: l.referenceRange.map {
                [FHIRReferenceRange(
                    low:  FHIRQuantity(value: $0.low,  unit: $0.units, system: "http://unitsofmeasure.org", code: $0.units),
                    high: FHIRQuantity(value: $0.high, unit: $0.units, system: "http://unitsofmeasure.org", code: $0.units)
                )]
            }
        )
    }

    private static func mapVital(_ v: VitalSignEntry, patient: FHIRReference) -> FHIRObservation {
        FHIRObservation(
            id: v.id,
            status: "final",
            code: FHIRCodeableConcept(
                coding: [FHIRCoding(system: "http://loinc.org", code: v.loincCode, display: v.displayName)],
                text: v.displayName
            ),
            subject: patient,
            effectiveDateTime: v.observationDate,
            valueQuantity: FHIRQuantity(
                value: v.value.magnitude,
                unit: v.value.units,
                system: "http://unitsofmeasure.org",
                code: v.value.units
            ),
            referenceRange: nil
        )
    }

    private static func snomedStatus(_ status: String) -> FHIRCodeableConcept {
        FHIRCodeableConcept(
            coding: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/condition-clinical", code: status, display: nil)],
            text: status
        )
    }
}
