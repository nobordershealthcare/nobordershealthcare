// PDFImporter.swift — imports PDF files into the DocumentVault.
//
// Strategy:
//   1. Open the file with PDFKit.
//   2. For each page, attempt to extract the native text layer (PDFPage.string).
//   3. If a page has no text layer (image-only / scanned PDF), rasterize it
//      to UIImage at 2× scale and pass to LocalOCR for Vision-based recognition.
//   4. Return one PDFPageResult per page, tagged with the text extraction source.
//
// No network calls. All processing is on-device.
// Security-scoped resource access is handled for Files-app URLs.

import PDFKit
import UIKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PDFPageResult

/// The extracted content for a single PDF page.
struct PDFPageResult: Sendable {
    /// Zero-based page index.
    let pageIndex: Int
    /// Page rasterized to UIImage at 2× the PDF's natural point resolution.
    let image: UIImage
    /// Extracted text — from the native PDF text layer or from Vision OCR.
    let extractedText: String
    /// Identifies how the text was obtained.
    let source: TextSource

    enum TextSource: String, Sendable {
        /// Native PDF text layer (PDFPage.string). Lossless, instant.
        case textLayer
        /// Vision VNRecognizeTextRequest — used when no text layer exists.
        case ocr
    }
}

// MARK: - PDFImporter

/// Reads a PDF from a file URL, extracts text (with OCR fallback), and
/// rasterizes each page to a UIImage ready for vault storage.
actor PDFImporter {

    static let shared = PDFImporter()

    /// Render scale relative to the PDF's native point size.
    /// 2.0 ≈ 144 DPI on a standard A4 page — good quality, manageable file size.
    private static let renderScale: CGFloat = 2.0

    // ── Error type ────────────────────────────────────────────────────────

    enum PDFError: LocalizedError {
        case cannotOpen(URL)
        case emptyDocument
        case renderFailed(Int)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let url):
                return "PDFImporter: cannot open '\(url.lastPathComponent)'"
            case .emptyDocument:
                return "PDFImporter: document contains no pages"
            case .renderFailed(let p):
                return "PDFImporter: failed to render page \(p + 1)"
            }
        }
    }

    // ── Public API ────────────────────────────────────────────────────────

    /// Import a PDF from `url` and return one `PDFPageResult` per page.
    ///
    /// - Parameter url: File URL (e.g. from `UIDocumentPickerViewController`).
    ///   Security-scoped access is started and stopped automatically.
    /// - Returns: Array of `PDFPageResult` in page order.
    /// - Throws: `PDFError` if the file cannot be opened or is empty.
    func importPDF(at url: URL) async throws -> [PDFPageResult] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: url) else {
            throw PDFError.cannotOpen(url)
        }
        guard document.pageCount > 0 else {
            throw PDFError.emptyDocument
        }

        var results = [PDFPageResult]()
        results.reserveCapacity(document.pageCount)

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let result = try await processPage(page, index: i)
            results.append(result)
        }
        return results
    }

    // ── Per-page extraction ───────────────────────────────────────────────

    private func processPage(_ page: PDFPage, index: Int) async throws -> PDFPageResult {
        // Always rasterize — used for display and vault thumbnail generation.
        let image = try renderPage(page, index: index)

        // Check for native text layer.
        let nativeText = page.string ?? ""
        let hasTextLayer = !nativeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasTextLayer {
            return PDFPageResult(
                pageIndex:     index,
                image:         image,
                extractedText: nativeText,
                source:        .textLayer
            )
        } else {
            // Image-only page — fall back to on-device Vision OCR.
            let ocrResult = try await LocalOCR.shared.recognizePage(image, index: index)
            return PDFPageResult(
                pageIndex:     index,
                image:         image,
                extractedText: ocrResult.rawText,
                source:        .ocr
            )
        }
    }

    // ── Rasterization ─────────────────────────────────────────────────────

    private func renderPage(_ page: PDFPage, index: Int) throws -> UIImage {
        let mediaBox = page.bounds(for: .mediaBox)
        let scale    = Self.renderScale
        let size     = CGSize(
            width:  mediaBox.width  * scale,
            height: mediaBox.height * scale
        )

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // White background so transparent PDFs render correctly.
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        return image
    }
}

// MARK: - PDFPickerView

/// SwiftUI wrapper around `UIDocumentPickerViewController` scoped to PDF files.
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $showPicker) {
///     PDFPickerView { url in
///         Task { await store.importPDF(at: url) }
///     } onCancel: {
///         showPicker = false
///     }
/// }
/// ```
struct PDFPickerView: UIViewControllerRepresentable {

    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pdf])
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIDocumentPickerDelegate {

        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick   = onPick
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { onCancel(); return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
