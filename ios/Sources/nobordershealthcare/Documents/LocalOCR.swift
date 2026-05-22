// LocalOCR.swift — offline text recognition via the Vision framework.
//
// PRIVACY: VNRecognizeTextRequest processes images entirely on-device.
// No image data, no recognized text, and no OCR results leave the device.
//
// Supported recognition languages (pilot set — matches xLMEngine):
//   uk-UA  Ukrainian
//   de-DE  German
//   pt-BR  Portuguese
//   ru-RU  Russian
//   en-US  English (guaranteed fallback)
//
// Vision selects the best-fitting language model automatically when
// multiple languages are passed to recognitionLanguages. The .accurate
// recognition level is used throughout; it is slower than .fast but
// significantly better for medical terminology, small fonts, and stamps.

import Vision
import UIKit

// MARK: - PageOCRResult

/// The recognized text and metadata for a single document page.
struct PageOCRResult: Sendable {
    /// Zero-based page index matching the input UIImage array position.
    let pageIndex: Int
    /// Full page text joined from all VNRecognizedTextObservation candidates,
    /// separated by newlines (one observation ≈ one line of text).
    let rawText: String
    /// Individual text observations in reading order (top-to-bottom, left-to-right).
    let observations: [String]
    /// Mean confidence across all top-candidate observations (0 … 1).
    let confidence: Float
}

// MARK: - LocalOCR

/// Performs offline optical character recognition using Vision's
/// `VNRecognizeTextRequest`. All work is dispatched to Vision's internal
/// thread pool via `VNImageRequestHandler.perform(_:)` — the calling actor
/// is never blocked for longer than the async suspension.
actor LocalOCR {

    static let shared = LocalOCR()

    // Recognition language candidates in priority order.
    // Vision filters this list against what the installed model set supports.
    private static let candidateLanguages: [String] = [
        "uk-UA",    // Ukrainian
        "de-DE",    // German
        "pt-BR",    // Portuguese
        "ru-RU",    // Russian
        "en-US",    // English — guaranteed to be present on all devices
    ]

    // ── Error type ────────────────────────────────────────────────────────

    enum OCRError: LocalizedError {
        case cgImageConversionFailed
        case recognitionFailed(String)
        case noTextDetected

        var errorDescription: String? {
            switch self {
            case .cgImageConversionFailed:
                return "LocalOCR: failed to extract CGImage from UIImage"
            case .recognitionFailed(let reason):
                return "LocalOCR: Vision request failed — \(reason)"
            case .noTextDetected:
                return "LocalOCR: no text found in image"
            }
        }
    }

    // ── Supported language cache ──────────────────────────────────────────

    // Cached at first use so we don't query Vision on every page.
    private var filteredLanguages: [String]?

    private func recognitionLanguages() -> [String] {
        if let cached = filteredLanguages { return cached }
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate, revision: VNRecognizeTextRequestRevision3
        )) ?? []
        let filtered = Self.candidateLanguages.filter { supported.contains($0) }
        let result = filtered.isEmpty ? ["en-US"] : filtered
        filteredLanguages = result
        return result
    }

    // ── Public API ────────────────────────────────────────────────────────

    /// Recognize text in a single document-page image.
    ///
    /// - Parameters:
    ///   - image: UIImage of one document page. Higher resolution (≥ 150 DPI)
    ///            produces significantly better results for medical text.
    ///   - index: Zero-based page index; passed through to the result.
    /// - Returns: `PageOCRResult` with raw text and per-observation strings.
    /// - Throws: `OCRError` if Vision fails or no text is found.
    func recognizePage(_ image: UIImage, index: Int) async throws -> PageOCRResult {
        guard let cgImage = image.cgImage else {
            throw OCRError.cgImageConversionFailed
        }
        let langs = recognitionLanguages()
        return try await withCheckedThrowingContinuation { continuation in
            performOCR(on: cgImage, pageIndex: index, languages: langs, continuation: continuation)
        }
    }

    /// Recognize text across all pages of a document sequentially.
    ///
    /// - Parameter images: One UIImage per page, in document order.
    /// - Returns: Array of `PageOCRResult`, one per image.
    func recognizeDocument(_ images: [UIImage]) async throws -> [PageOCRResult] {
        var results = [PageOCRResult]()
        results.reserveCapacity(images.count)
        for (i, image) in images.enumerated() {
            let result = try await recognizePage(image, index: i)
            results.append(result)
        }
        return results
    }

    // ── Internal Vision dispatch ──────────────────────────────────────────

    private func performOCR(
        on cgImage: CGImage,
        pageIndex: Int,
        languages: [String],
        continuation: CheckedContinuation<PageOCRResult, Error>
    ) {
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
                return
            }

            guard
                let observations = request.results as? [VNRecognizedTextObservation],
                !observations.isEmpty
            else {
                continuation.resume(throwing: OCRError.noTextDetected)
                return
            }

            // Take the top candidate for each observation (highest confidence).
            let candidates = observations.compactMap { $0.topCandidates(1).first }
            let strings     = candidates.map(\.string)
            let confidences = candidates.map(\.confidence)
            let meanConf    = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Float(confidences.count)

            let result = PageOCRResult(
                pageIndex:    pageIndex,
                rawText:      strings.joined(separator: "\n"),
                observations: strings,
                confidence:   meanConf
            )
            continuation.resume(returning: result)
        }

        // .accurate: slower but essential for medical terminology, stamps, and
        // small-font prescription text. .fast is not sufficient for this use case.
        request.recognitionLevel          = .accurate
        request.usesLanguageCorrection    = true
        request.recognitionLanguages      = languages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
        }
    }
}
