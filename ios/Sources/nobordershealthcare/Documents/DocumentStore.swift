// DocumentStore.swift — Encrypted document vault: domain types and storage manager.
//
// Documents live in Silo 1 (eHR vault, VaultManager) as AES-256-GCM blobs:
//   index.enc          — encrypted [VaultDocument] metadata list
//   {uuid}-pages.enc   — encrypted [PageData] per document
//   {uuid}-thumb.enc   — encrypted JPEG thumbnail (first page, 120 px)
//
// All data passes through VaultManager.seal() / open() — the same key as the eHR vault.
// Raw scan images and OCR text are NEVER written to disk unencrypted.
// DocumentTranslator calls xLMEngine.translateMedical() — NEVER translateUI().

import Foundation
import SwiftUI
import UIKit

// MARK: - Domain types

enum DocumentSource: String, Codable, Sendable {
    case camera
    case pdf

    var displayName: String {
        switch self {
        case .camera: "Scanned"
        case .pdf:    "PDF Import"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "doc.viewfinder"
        case .pdf:    "doc.fill"
        }
    }
}

/// Lightweight document metadata stored in the encrypted index.
/// Does NOT contain page images or OCR text — those are loaded on demand.
struct VaultDocument: Codable, Sendable, Identifiable {
    let id: UUID
    var title: String
    let source: DocumentSource
    let pageCount: Int
    let createdAt: Date
}

/// Full content for one page of a VaultDocument.
struct PageData: Codable, Sendable {
    let index: Int
    /// JPEG-compressed page image (quality 0.75, ~200–600 KB per page).
    let jpegData: Data
    /// Raw OCR output or PDF text-layer content.
    let ocrText: String
    /// BCP-47 primary subtag of the detected source language (e.g. "en", "uk").
    let sourceLanguage: String
    /// On-device translations keyed by target language code: "uk" → "...", "pt" → "..."
    /// Empty for non-English source documents (reverse opus-mt models not yet bundled).
    var translations: [String: String]
}

// MARK: - DocumentStore

/// Manages encrypted document storage and drives the scan → OCR → translate → encrypt pipeline.
@MainActor
final class DocumentStore: ObservableObject {

    static let shared = DocumentStore()

    @Published var documents: [VaultDocument] = []
    @Published var processingMessage: String? = nil  // nil = idle

    // ── Vault directory layout ────────────────────────────────────────────────

    private let vaultDir: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = base.appendingPathComponent("vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var indexURL:    URL { vaultDir.appendingPathComponent("index.enc") }
    private func pagesURL(for id: UUID) -> URL  { vaultDir.appendingPathComponent("\(id)-pages.enc") }
    private func thumbURL(for id: UUID) -> URL  { vaultDir.appendingPathComponent("\(id)-thumb.enc") }

    // In-memory thumbnail cache (UIImage is not Sendable — kept on main actor).
    private var thumbnailCache: [UUID: UIImage] = [:]

    // MARK: - Load

    func loadIndex() async {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let encData = try Data(contentsOf: indexURL)
            let sealed  = try JSONDecoder().decode(VaultManager.SealedVault.self, from: encData)
            let plain   = try await VaultManager.shared.open(sealed)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            documents = try decoder.decode([VaultDocument].self, from: plain)
        } catch {
            documents = []
        }
    }

    // MARK: - Thumbnail

    func thumbnail(for id: UUID) -> UIImage? { thumbnailCache[id] }

    func prefetchThumbnail(for id: UUID) {
        guard thumbnailCache[id] == nil else { return }
        Task {
            guard let img = await loadThumbnail(id: id) else { return }
            thumbnailCache[id] = img
            objectWillChange.send()
        }
    }

    private func loadThumbnail(id: UUID) async -> UIImage? {
        let url = thumbURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path),
              let encData  = try? Data(contentsOf: url),
              let sealed   = try? JSONDecoder().decode(VaultManager.SealedVault.self, from: encData),
              let jpegData = try? await VaultManager.shared.open(sealed) else { return nil }
        return UIImage(data: jpegData)
    }

    // MARK: - Load pages

    func loadPages(for documentID: UUID) async throws -> [PageData] {
        let url     = pagesURL(for: documentID)
        let encData = try Data(contentsOf: url)
        let sealed  = try JSONDecoder().decode(VaultManager.SealedVault.self, from: encData)
        let plain   = try await VaultManager.shared.open(sealed)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PageData].self, from: plain)
    }

    // MARK: - Add from camera scan

    func addScannedDocument(images: [UIImage], title: String) async {
        await addDocument(images: images, source: .camera, title: title)
    }

    // MARK: - Add from PDF

    func addPDF(at url: URL) async {
        processingMessage = "Reading PDF…"
        do {
            let pdfPages = try await PDFImporter.shared.importPDF(at: url)
            let images   = pdfPages.map(\.image)
            let title    = url.deletingPathExtension().lastPathComponent
            await addDocument(images: images, source: .pdf, title: title)
        } catch {
            processingMessage = nil
        }
    }

    // MARK: - Core pipeline (OCR → Translate → Encrypt → Save)

    private func addDocument(images: [UIImage], source: DocumentSource, title: String) async {
        let id = UUID()

        // ── OCR ───────────────────────────────────────────────────────────────
        processingMessage = "Recognizing text (0/\(images.count))…"
        var ocrResults = [PageOCRResult]()
        for (i, img) in images.enumerated() {
            processingMessage = "Recognizing text (\(i + 1)/\(images.count))…"
            if let result = try? await LocalOCR.shared.recognizePage(img, index: i) {
                ocrResults.append(result)
            } else {
                ocrResults.append(PageOCRResult(pageIndex: i, rawText: "", observations: [], confidence: 0))
            }
        }

        // ── Translation ───────────────────────────────────────────────────────
        processingMessage = "Translating (0/\(ocrResults.count))…"
        var translatedPages = [TranslatedPage]()
        for (i, page) in ocrResults.enumerated() {
            processingMessage = "Translating (\(i + 1)/\(ocrResults.count))…"
            let tp = await DocumentTranslator.shared.translateDocument([page])
            translatedPages.append(contentsOf: tp)
        }

        // ── Build PageData array ──────────────────────────────────────────────
        processingMessage = "Encrypting…"
        var pages = [PageData]()
        for (i, img) in images.enumerated() {
            let jpegData = img.jpegData(compressionQuality: 0.75) ?? Data()
            let tp       = translatedPages.first(where: { $0.pageIndex == i })
            pages.append(PageData(
                index:          i,
                jpegData:       jpegData,
                ocrText:        tp?.originalText ?? "",
                sourceLanguage: tp?.sourceLanguage ?? "en",
                translations:   tp?.translations ?? [:]
            ))
        }

        // ── Thumbnail (first page, 120 px wide) ───────────────────────────────
        if let firstImage = images.first {
            let thumb = makeThumbnail(firstImage, width: 120)
            if let thumbJPEG = thumb?.jpegData(compressionQuality: 0.6) {
                _ = try? await encryptAndSave(thumbJPEG, to: thumbURL(for: id))
                thumbnailCache[id] = thumb
            }
        }

        // ── Encrypt and save pages ─────────────────────────────────────────────
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let pagesData = try? encoder.encode(pages) {
            _ = try? await encryptAndSave(pagesData, to: pagesURL(for: id))
        }

        // ── Update index ──────────────────────────────────────────────────────
        let doc = VaultDocument(id: id, title: title, source: source, pageCount: images.count, createdAt: Date())
        documents.insert(doc, at: 0)
        await saveIndex()
        processingMessage = nil
    }

    // MARK: - Delete

    func deleteDocument(_ id: UUID) async {
        documents.removeAll { $0.id == id }
        thumbnailCache.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: pagesURL(for: id))
        try? FileManager.default.removeItem(at: thumbURL(for: id))
        await saveIndex()
    }

    // MARK: - Helpers

    private func saveIndex() async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let plain = try? encoder.encode(documents) else { return }
        _ = try? await encryptAndSave(plain, to: indexURL)
    }

    @discardableResult
    private func encryptAndSave(_ data: Data, to url: URL) async throws -> URL {
        let sealed  = try await VaultManager.shared.seal(data)
        let encData = try JSONEncoder().encode(sealed)
        try encData.write(to: url, options: .atomic)
        return url
    }

    private func makeThumbnail(_ image: UIImage, width: CGFloat) -> UIImage? {
        let scale    = width / image.size.width
        let height   = image.size.height * scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }
    }
}
