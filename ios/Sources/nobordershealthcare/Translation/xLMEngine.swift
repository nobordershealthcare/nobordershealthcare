// On-device label translation using the iOS 26 Translation framework.
// Translates DISPLAY LABELS ONLY — never codes, never raw patient data.
// Input invariants enforced: short strings only, no structured medical data.
// xLMEngine is injected with a TranslationSession from the SwiftUI view layer.

import Foundation
@preconcurrency import Translation  // TranslationSession lacks Sendable annotation in current SDK

// MARK: - Engine

// @MainActor: TranslationSession is @MainActor-isolated in the Translation framework.
// All callers must be on the main actor (SwiftUI views, @MainActor-annotated sites).
@MainActor
final class xLMEngine {

    static let shared = xLMEngine()

    // Injected from the SwiftUI .translationTask modifier on the root health card view.
    // Falls back to the original label (no translation) if no session is available.
    var session: TranslationSession?

    // Translates a single display label (e.g. "Glycated haemoglobin A1c") to the target language.
    // NEVER call with: ICD codes, SNOMED IDs, LOINC codes, medication names from raw documents,
    // patient identifiers, or any text longer than 200 characters.
    func translate(_ label: String, to targetLanguage: String) async throws -> String {
        assert(label.count <= 200, "xLMEngine: label too long — check TerminologyMapper")
        guard let session else { return label }
        let response = try await session.translate(label)
        return response.targetText
    }

    // Batch translation via sequential calls — avoids relying on a specific batch API version.
    func translateBatch(_ labels: [String], to targetLanguage: String) async throws -> [String] {
        guard let session else { return labels }
        var results = [String]()
        results.reserveCapacity(labels.count)
        for label in labels {
            let response = try await session.translate(label)
            results.append(response.targetText)
        }
        return results
    }
}

// MARK: - TerminologyMapper + xLMEngine integration

// The combined lookup: code → English label → translated label.
// This is the only sanctioned path for displaying terminology to users.
@MainActor
enum LocalizedTerminology {

    static func label(
        code: String,
        system: TerminologyMapper.TerminologySystem,
        targetLanguage: String
    ) async -> String {
        let english = TerminologyMapper.englishLabel(code: code, system: system)
        guard !targetLanguage.hasPrefix("en") else { return english }
        return (try? await xLMEngine.shared.translate(english, to: targetLanguage)) ?? english
    }
}
