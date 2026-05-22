// DocumentView.swift — DocumentVault UI and encrypted storage layer.
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  DATA FLOW                                                              │
// │                                                                         │
// │  Scan / Import PDF                                                      │
// │      ↓                                                                  │
// │  LocalOCR (Vision, on-device)                                           │
// │      ↓                                                                  │
// │  DocumentTranslator → xLMEngine.translateMedical() (opus-mt CoreML)    │
// │      ↓                                                                  │
// │  VaultManager.seal() (AES-256-GCM, SE-wrapped key)                     │
// │      ↓                                                                  │
// │  ~/Documents/vault/                                                     │
// │      index.enc         — encrypted [VaultDocument] metadata             │
// │      {uuid}-pages.enc  — encrypted [PageData] per document             │
// │      {uuid}-thumb.enc  — encrypted JPEG thumbnail (first page, small)  │
// └─────────────────────────────────────────────────────────────────────────┘
//
// Integration: use DocumentView() as the body of RecordsView in ContentView.swift,
// or present it as a NavigationLink destination from any view.

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

/// Lightweight document record stored in the encrypted index.
/// Does NOT contain page images or OCR text — load those on demand.
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
    /// Raw OCR or PDF text-layer output.
    let ocrText: String
    /// BCP-47 primary subtag of the detected source language.
    let sourceLanguage: String
    /// On-device translations: "uk" → "…", "ru" → "…", etc.
    /// Empty if source is not English (reverse opus-mt models not yet bundled).
    var translations: [String: String]
}

// MARK: - DocumentStore

/// Manages encrypted document storage and drives the scan/import pipeline.
@MainActor
final class DocumentStore: ObservableObject {

    static let shared = DocumentStore()

    @Published var documents: [VaultDocument] = []
    @Published var processingMessage: String? = nil  // nil = idle

    // ── Vault directory layout ────────────────────────────────────────────

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
            documents   = try JSONDecoder().decode([VaultDocument].self, from: plain)
        } catch {
            // Index unreadable — start with an empty vault.
            documents = []
        }
    }

    // MARK: - Thumbnail

    /// Returns a cached UIImage thumbnail for `id`, or nil if not yet loaded.
    func thumbnail(for id: UUID) -> UIImage? { thumbnailCache[id] }

    /// Loads and decrypts the thumbnail for `id` in the background.
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
              let encData = try? Data(contentsOf: url),
              let sealed  = try? JSONDecoder().decode(VaultManager.SealedVault.self, from: encData),
              let jpegData = try? await VaultManager.shared.open(sealed) else { return nil }
        return UIImage(data: jpegData)
    }

    // MARK: - Load pages

    func loadPages(for documentID: UUID) async throws -> [PageData] {
        let url     = pagesURL(for: documentID)
        let encData = try Data(contentsOf: url)
        let sealed  = try JSONDecoder().decode(VaultManager.SealedVault.self, from: encData)
        let plain   = try await VaultManager.shared.open(sealed)
        return try JSONDecoder().decode([PageData].self, from: plain)
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

        // ── OCR ───────────────────────────────────────────────────────────
        processingMessage = "Recognizing text (0/\(images.count))…"
        var ocrResults = [PageOCRResult]()
        for (i, img) in images.enumerated() {
            processingMessage = "Recognizing text (\(i + 1)/\(images.count))…"
            if let result = try? await LocalOCR.shared.recognizePage(img, index: i) {
                ocrResults.append(result)
            } else {
                // OCR failed for this page — store blank text, still keep the image.
                ocrResults.append(PageOCRResult(
                    pageIndex:    i,
                    rawText:      "",
                    observations: [],
                    confidence:   0
                ))
            }
        }

        // ── Translation ───────────────────────────────────────────────────
        processingMessage = "Translating (0/\(ocrResults.count))…"
        var translatedPages = [TranslatedPage]()
        for (i, page) in ocrResults.enumerated() {
            processingMessage = "Translating (\(i + 1)/\(ocrResults.count))…"
            let tp = await DocumentTranslator.shared.translateDocument([page])
            translatedPages.append(contentsOf: tp)
        }

        // ── Build PageData array ──────────────────────────────────────────
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

        // ── Thumbnail (first page, 120 px wide) ───────────────────────────
        if let firstImage = images.first {
            let thumb = makeThumbnail(firstImage, width: 120)
            if let thumbJPEG = thumb?.jpegData(compressionQuality: 0.6) {
                _ = try? await encryptAndSave(thumbJPEG, to: thumbURL(for: id))
                thumbnailCache[id] = thumb
            }
        }

        // ── Encrypt and save pages ─────────────────────────────────────────
        if let pagesData = try? JSONEncoder().encode(pages) {
            _ = try? await encryptAndSave(pagesData, to: pagesURL(for: id))
        }

        // ── Update index ──────────────────────────────────────────────────
        let doc = VaultDocument(
            id:        id,
            title:     title,
            source:    source,
            pageCount: images.count,
            createdAt: Date()
        )
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
        guard let plain = try? JSONEncoder().encode(documents) else { return }
        _ = try? await encryptAndSave(plain, to: indexURL)
    }

    /// Seal `data` with VaultManager, then write to `url`.
    @discardableResult
    private func encryptAndSave(_ data: Data, to url: URL) async throws -> URL {
        let sealed    = try await VaultManager.shared.seal(data)
        let encData   = try JSONEncoder().encode(sealed)
        try encData.write(to: url, options: .atomic)
        return url
    }

    private func makeThumbnail(_ image: UIImage, width: CGFloat) -> UIImage? {
        let scale  = width / image.size.width
        let height = image.size.height * scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }
    }
}

// MARK: - DocumentView

/// Root document-vault screen.
/// Wire into RecordsView:
/// ```swift
/// // ContentView.swift — RecordsView.body
/// var body: some View { DocumentView() }
/// ```
struct DocumentView: View {

    @StateObject private var store = DocumentStore.shared
    @State private var showScanner  = false
    @State private var showPicker   = false
    @State private var selected: VaultDocument? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                if store.documents.isEmpty && store.processingMessage == nil {
                    emptyState
                } else {
                    documentList
                }

                // Processing banner (OCR + translation in progress)
                if let msg = store.processingMessage {
                    processingBanner(message: msg)
                }
            }
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if DocumentScannerView.isAvailable {
                        Button { showScanner = true } label: {
                            Label("Scan", systemImage: "doc.viewfinder")
                        }
                        .glassEffect(in: Capsule())
                    }
                    Button { showPicker = true } label: {
                        Label("Import PDF", systemImage: "doc.badge.plus")
                    }
                    .glassEffect(in: Capsule())
                }
            }
        }
        .task { await store.loadIndex() }
        // ── Scanner sheet ──────────────────────────────────────────────────
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { images in
                showScanner = false
                Task {
                    let title = "Scan \(DocumentView.scanDateString())"
                    await store.addScannedDocument(images: images, title: title)
                }
            } onCancel: {
                showScanner = false
            }
        }
        // ── PDF picker sheet ───────────────────────────────────────────────
        .sheet(isPresented: $showPicker) {
            PDFPickerView { url in
                showPicker = false
                Task { await store.addPDF(at: url) }
            } onCancel: {
                showPicker = false
            }
        }
        // ── Document detail ────────────────────────────────────────────────
        .sheet(item: $selected) { doc in
            DocumentDetailView(document: doc)
        }
    }

    // ── Document list ──────────────────────────────────────────────────────

    private var documentList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.documents) { doc in
                    DocumentRowView(document: doc, store: store)
                        .onTapGesture { selected = doc }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // ── Empty state ────────────────────────────────────────────────────────

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(Color.navy.opacity(0.35))
            Text("No Documents")
                .font(.title3).fontWeight(.semibold)
            Text("Scan a physical document or\nimport a PDF to get started.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Processing banner ──────────────────────────────────────────────────

    private func processingBanner(message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text(message)
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Color.navy)
            .clipShape(Capsule())
            .shadow(radius: 8, y: 4)
            .padding(.bottom, 100)
        }
        .animation(.spring, value: message)
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private static func scanDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy HH:mm"
        return f.string(from: Date())
    }
}

// MARK: - DocumentRowView

struct DocumentRowView: View {
    let document: VaultDocument
    let store: DocumentStore

    var body: some View {
        HStack(spacing: 14) {
            // ── Thumbnail ────────────────────────────────────────────────
            thumbnailView
                .frame(width: 56, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // ── Metadata ─────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.subheadline).fontWeight(.semibold)
                    .lineLimit(2)
                Text(document.createdAt, style: .date)
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: document.source.systemImage)
                        .font(.caption2)
                    Text(document.source.displayName)
                        .font(.caption2)
                    Text("·")
                    Text("\(document.pageCount) \(document.pageCount == 1 ? "page" : "pages")")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { store.prefetchThumbnail(for: document.id) }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let img = store.thumbnail(for: document.id) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: document.source.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.navy.opacity(0.4))
            }
        }
    }
}

// MARK: - DocumentDetailView

struct DocumentDetailView: View {

    let document: VaultDocument
    @StateObject private var store = DocumentStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pages: [PageData] = []
    @State private var currentPage = 0
    @State private var selectedLang: String = "original"
    @State private var isLoading = true

    // Available language tabs: "original" + any translated languages present.
    private var availableLangs: [String] {
        var langs = ["original"]
        if let first = pages.first {
            for lang in DocumentTranslator.targetLanguages where first.translations[lang] != nil {
                langs.append(lang)
            }
        }
        return langs
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pages.isEmpty {
                    Text("No content available.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        pageImageCarousel
                        languagePicker
                        textContent
                    }
                }
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        Task {
                            await store.deleteDocument(document.id)
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .task {
            isLoading = true
            pages = (try? await store.loadPages(for: document.id)) ?? []
            isLoading = false
        }
    }

    // ── Page image carousel ───────────────────────────────────────────────

    private var pageImageCarousel: some View {
        TabView(selection: $currentPage) {
            ForEach(pages, id: \.index) { page in
                if let img = UIImage(data: page.jpegData) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 16)
                        .tag(page.index)
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
        .frame(height: 260)
        .background(.ultraThinMaterial)
    }

    // ── Language picker ────────────────────────────────────────────────────

    private var languagePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableLangs, id: \.self) { lang in
                    Button {
                        selectedLang = lang
                    } label: {
                        Text(langLabel(lang))
                            .font(.caption).fontWeight(.semibold)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(selectedLang == lang ? Color.navy : Color.secondary.opacity(0.15))
                            .foregroundStyle(selectedLang == lang ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    // ── Text content panel ─────────────────────────────────────────────────

    private var textContent: some View {
        ScrollView {
            let page = pages.first(where: { $0.index == currentPage }) ?? pages.first
            let text: String = {
                guard let p = page else { return "" }
                if selectedLang == "original" { return p.ocrText }
                return p.translations[selectedLang] ?? noTranslationMessage(for: selectedLang, source: p.sourceLanguage)
            }()

            Text(text.isEmpty ? "No text recognized on this page." : text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private func langLabel(_ lang: String) -> String {
        switch lang {
        case "original": return "🗒 Original"
        case "uk":       return "🇺🇦 Ukrainian"
        case "ru":       return "🇷🇺 Russian"
        case "de":       return "🇩🇪 German"
        case "pt":       return "🇵🇹 Portuguese"
        default:         return lang.uppercased()
        }
    }

    private func noTranslationMessage(for lang: String, source: String) -> String {
        // Non-English source: reverse opus-mt models not yet bundled.
        "Translation unavailable — source language '\(source)' → '\(lang)' model not yet installed.\n\nOn-device translation supports English source documents only in this release."
    }
}

// MARK: - Preview

#Preview {
    DocumentView()
        .environmentObject(NetworkCountryDetector.shared)
}
