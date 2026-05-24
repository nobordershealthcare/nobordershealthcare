// DocumentView.swift — DocumentVault views.
//
// Domain types (DocumentSource, VaultDocument, PageData) and DocumentStore
// are defined in DocumentStore.swift.
//
// Integration: use DocumentView() as the body of RecordsView in ContentView.swift.

import SwiftUI
import UIKit

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
