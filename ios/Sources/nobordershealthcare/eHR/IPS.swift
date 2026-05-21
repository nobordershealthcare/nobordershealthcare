// International Patient Summary (IPS) builder.
// Profile: HL7 FHIR R4 IPS IG (STU 1.1).
// Produces a FHIR Bundle of type "document" containing the IPS Composition.
// Works offline — no network required to generate a summary from local data.

import Foundation

enum IPS {

    // Sections required by the IPS profile
    enum SectionCode: String {
        case allergies   = "48765-2"   // LOINC: Allergies and adverse reactions
        case medications = "10160-0"   // LOINC: Medication summary
        case problems    = "11450-4"   // LOINC: Problem list
        case results     = "30954-2"   // LOINC: Results
        case vitalSigns  = "8716-3"    // LOINC: Vital signs (optional)
    }

    static func build(
        from composition: Composition,
        patientHash: String,
        scope: IPSScopeFilter = .all
    ) -> FHIRBundle {
        let filtered = applyScope(to: composition, scope: scope)
        var bundle = FHIRMapper.bundle(from: filtered, patientHash: patientHash)

        // Replace the generic bundle type with IPS document type
        // and inject the IPS Composition resource
        let ipsComposition = makeIPSComposition(from: filtered, patientHash: patientHash)
        bundle.entry.insert(
            FHIRBundleEntry(fullURL: "urn:uuid:\(composition.id)-ips", resource: .composition(ipsComposition)),
            at: 0
        )
        return bundle
    }

    // MARK: - IPS Composition

    private static func makeIPSComposition(from composition: Composition, patientHash: String) -> FHIRComposition {
        var sections: [FHIRSection] = []

        for section in composition.sections {
            let refs = section.entries.compactMap { entry -> FHIRReference? in
                switch entry {
                case .allergy(let a):    return FHIRReference(reference: "AllergyIntolerance/\(a.id)")
                case .medication(let m): return FHIRReference(reference: "MedicationStatement/\(m.id)")
                case .condition(let c):  return FHIRReference(reference: "Condition/\(c.id)")
                case .labResult(let l):  return FHIRReference(reference: "Observation/\(l.id)")
                case .vitalSign(let v):  return FHIRReference(reference: "Observation/\(v.id)")
                }
            }
            guard !refs.isEmpty else { continue }
            sections.append(FHIRSection(
                title: section.name,
                code: FHIRCodeableConcept(
                    coding: [FHIRCoding(system: "http://loinc.org", code: sectionLOINC(for: section), display: section.name)],
                    text: section.name
                ),
                entry: refs
            ))
        }

        return FHIRComposition(
            id: composition.id,
            status: "final",
            type: FHIRCodeableConcept(
                coding: [FHIRCoding(system: "http://loinc.org", code: "60591-5", display: "Patient summary Document")],
                text: "International Patient Summary"
            ),
            subject: FHIRReference(reference: "Patient/\(patientHash)"),
            date: composition.dateCreated,
            author: [FHIRReference(reference: "Device/ios-wallet")],
            title: "International Patient Summary",
            section: sections
        )
    }

    // MARK: - Scope filtering

    static func applyScope(to composition: Composition, scope: IPSScopeFilter) -> Composition {
        guard scope != .all else { return composition }

        var filtered = composition
        filtered.sections = composition.sections.compactMap { section in
            let entries = section.entries.filter { entry in
                switch entry {
                case .allergy:    return scope.contains(.allergies)
                case .medication: return scope.contains(.medications)
                case .condition:  return scope.contains(.problems)
                case .labResult:  return scope.contains(.results)
                case .vitalSign:  return scope.contains(.vitalSigns)
                }
            }
            guard !entries.isEmpty else { return nil }
            var s = section
            s.entries = entries
            return s
        }
        return filtered
    }

    private static func sectionLOINC(for section: EHRSection) -> String {
        let name = section.name.lowercased()
        if name.contains("allerg")    { return SectionCode.allergies.rawValue }
        if name.contains("medic")     { return SectionCode.medications.rawValue }
        if name.contains("problem") || name.contains("condition") { return SectionCode.problems.rawValue }
        if name.contains("result") || name.contains("lab")        { return SectionCode.results.rawValue }
        if name.contains("vital")     { return SectionCode.vitalSigns.rawValue }
        return "34133-9"  // Summarization of episode note (default)
    }
}

// MARK: - Scope filter

struct IPSScopeFilter: OptionSet, Sendable {
    let rawValue: Int
    static let allergies   = IPSScopeFilter(rawValue: 1 << 0)
    static let medications = IPSScopeFilter(rawValue: 1 << 1)
    static let problems    = IPSScopeFilter(rawValue: 1 << 2)
    static let results     = IPSScopeFilter(rawValue: 1 << 3)
    static let vitalSigns  = IPSScopeFilter(rawValue: 1 << 4)
    static let all: IPSScopeFilter = [.allergies, .medications, .problems, .results, .vitalSigns]
    static let emergency: IPSScopeFilter = [.allergies, .medications, .problems]
}
