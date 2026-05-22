// DocumentTranslator.swift — translates OCR'd document text on-device.
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  ARCHITECTURE INVARIANT                                                 │
// │                                                                         │
// │  Document text is medical content. It MUST flow through                 │
// │  xLMEngine.translateMedical() → opus-mt CoreML, never through          │
// │  xLMEngine.translateUI() → Apple Translation (cloud-backed).           │
// │                                                                         │
// │  No OCR'd text and no translation output ever leaves the device.        │
// └─────────────────────────────────────────────────────────────────────────┘
//
// Translation direction: English source → {uk, ru, de, pt}
//   The bundled opus-mt-en-XX models only translate FROM English.
//   For non-English source documents, NLLanguageRecognizer detects the
//   source and the original text is stored as-is. Reverse-direction models
//   (e.g. opus-mt-de-en) are a future milestone.
//
// Chunking: xLMEngine enforces a 200-character input limit (matching
// opus-mt's 64-token encoder window). Long OCR pages are split at word /
// line boundaries into ≤ 180-character chunks before translation.
// Translated chunks are rejoined with a space separator.

import Foundation
import NaturalLanguage

// MARK: - TranslatedPage

/// Translation result for a single document page.
struct TranslatedPage: Codable, Sendable {
    /// Zero-based page index matching the corresponding PageOCRResult.
    let pageIndex: Int
    /// BCP-47 primary subtag of the detected source language (e.g. "en", "de").
    let sourceLanguage: String
    /// Raw OCR text for this page (used as the "Original" tab in the UI).
    let originalText: String
    /// On-device translations keyed by BCP-47 primary subtag.
    /// Empty if source is not English (reverse models not yet bundled).
    var translations: [String: String]
}

// MARK: - DocumentTranslator

/// Translates OCR page results to all pilot languages on-device.
///
/// Each translation call flows through `xLMEngine.shared.translateMedical()`
/// which uses opus-mt CoreML exclusively — zero network calls.
actor DocumentTranslator {

    static let shared = DocumentTranslator()

    /// Pilot language codes that have bundled opus-mt-en-XX models.
    static let targetLanguages: [String] = ["uk", "ru", "de", "pt"]

    /// Maximum characters per translation chunk (below xLMEngine's 200-char limit).
    private static let chunkMaxLength = 180

    // ── Public API ────────────────────────────────────────────────────────

    /// Translate OCR results for all pages of a document.
    ///
    /// Translation is attempted page-by-page. Pages whose source language is
    /// not English are stored with an empty translations dictionary — the UI
    /// shows them as "original only".
    ///
    /// - Parameter pages: Output from `LocalOCR.recognizeDocument(_:)`.
    /// - Returns: Array of `TranslatedPage`, same order as input.
    func translateDocument(_ pages: [PageOCRResult]) async -> [TranslatedPage] {
        var results = [TranslatedPage]()
        results.reserveCapacity(pages.count)
        for page in pages {
            let translated = await translatePage(page)
            results.append(translated)
        }
        return results
    }

    // ── Per-page translation ──────────────────────────────────────────────

    private func translatePage(_ page: PageOCRResult) async -> TranslatedPage {
        let source = detectLanguage(in: page.rawText)
        var translations: [String: String] = [:]

        // opus-mt models cover EN → {uk, ru, de, pt} only.
        // Skip translation for non-English sources; reverse models are future work.
        if source.hasPrefix("en") {
            for lang in Self.targetLanguages {
                let result = await translateChunked(page.rawText, to: lang)
                translations[lang] = result
            }
        }

        return TranslatedPage(
            pageIndex:      page.pageIndex,
            sourceLanguage: source,
            originalText:   page.rawText,
            translations:   translations
        )
    }

    // ── Chunked translation ───────────────────────────────────────────────

    /// Split text into chunks ≤ `chunkMaxLength` chars and translate each.
    private func translateChunked(_ text: String, to lang: String) async -> String {
        let chunks = splitIntoChunks(text, maxLength: Self.chunkMaxLength)
        var parts  = [String]()
        parts.reserveCapacity(chunks.count)

        for chunk in chunks {
            // translateMedical() is @MainActor async — Swift hops to main actor
            // for each call and returns to this actor's executor after resumption.
            // It never throws to callers: falls back to the input on failure.
            let out = await xLMEngine.shared.translateMedical(chunk, to: lang)
            parts.append(out)
        }

        return parts.joined(separator: " ")
    }

    // ── Language detection ────────────────────────────────────────────────

    /// Identify the dominant language of `text` using NLLanguageRecognizer.
    /// Returns the BCP-47 primary subtag ("en", "de", "uk", …).
    /// Falls back to "en" when confidence is below 50 % or detection fails.
    private func detectLanguage(in text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "en"
        }
        let recognizer = NLLanguageRecognizer()
        // Feed at most 1 000 characters — sufficient for language detection.
        recognizer.processString(String(text.prefix(1_000)))

        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard
            let best = hypotheses.max(by: { $0.value < $1.value }),
            best.value >= 0.50
        else { return "en" }

        return primarySubtag(best.key.rawValue)
    }

    private func primarySubtag(_ bcp47: String) -> String {
        if let sep = bcp47.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(bcp47[..<sep]).lowercased()
        }
        return bcp47.lowercased()
    }

    // ── Sentence / line chunking ──────────────────────────────────────────

    /// Split `text` into chunks of at most `maxLength` characters, breaking at
    /// line or word boundaries so each chunk fits in opus-mt's encoder window.
    private func splitIntoChunks(_ text: String, maxLength: Int) -> [String] {
        // Split at newlines first (natural OCR reading-order breaks).
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var chunks   = [String]()
        var current  = ""

        for line in lines {
            if line.count > maxLength {
                // Line itself too long — flush current and hard-split at words.
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: wordSplit(line, maxLength: maxLength))
            } else if current.isEmpty {
                current = line
            } else if current.count + 1 + line.count <= maxLength {
                current += " " + line
            } else {
                chunks.append(current)
                current = line
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.filter { !$0.isEmpty }
    }

    /// Split a single long string at word boundaries into chunks ≤ `maxLength`.
    private func wordSplit(_ text: String, maxLength: Int) -> [String] {
        var result  = [String]()
        var current = ""
        for word in text.split(separator: " ") {
            let w = String(word)
            if current.isEmpty {
                // Single word longer than limit — hard truncate.
                current = w.count <= maxLength ? w : String(w.prefix(maxLength))
            } else if current.count + 1 + w.count <= maxLength {
                current += " " + w
            } else {
                result.append(current)
                current = w.count <= maxLength ? w : String(w.prefix(maxLength))
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
