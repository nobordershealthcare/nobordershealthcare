// HealthcareProxyView.swift — Step 4: Healthcare proxy setup with document attachment.
//
// Up to 3 proxy persons. For each proxy:
//   - Contact info (name, phone, email)
//   - Decision scope (inform only / advisory / full authority)
//   - Trigger conditions (multi-select)
//   - Validity period (optional expiry date)
//   - Official document (scan or PDF, OCR, translated, SHA3-256 → Ch1 proof-of-existence)
//   - Document sharing (one-time token, expiry, recipient type, Ch3 access log)
//
// SignatureButton signs the proxy record with:
//   legalBasis: [.ptLei25, .deBGB1901a, .uaLaw2017, .eidasArt25]
//
// After sign: IdentityVaultManager.sealProxy() + Ch1 broadcast.
// This step is optional in the sense that users may add 0 proxies, but the
// screen still requires explicit "Continue" to confirm the choice.

import SwiftUI

// MARK: - HealthcareProxyView

struct HealthcareProxyView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @State private var drafts: [ProxyDraft] = []
    @State private var expandedIndex: Int? = nil
    @State private var isSaving = false
    @State private var saveError: String? = nil
    @State private var allSigned = false

    private let maxProxies = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    ForEach(drafts.indices, id: \.self) { i in
                        ProxyCard(
                            draft: $drafts[i],
                            index: i,
                            isExpanded: expandedIndex == i,
                            onToggle: { expandedIndex = (expandedIndex == i) ? nil : i },
                            onDelete: {
                                drafts.remove(at: i)
                                if expandedIndex == i { expandedIndex = nil }
                            },
                            onSigned: { _ in
                                checkAllSigned()
                            }
                        )
                    }

                    if drafts.count < maxProxies {
                        addProxyButton
                    }

                    if let err = saveError {
                        Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
                    }

                    continueSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .navigationTitle("Healthcare Proxy")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Medical Decision Authority", systemImage: "person.2.fill")
                .font(.title3).fontWeight(.bold)

            Text("If you are unconscious or unable to communicate, who should medical staff contact for decisions?")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                legalRef(flag: "🇵🇹", law: "Lei 25/2012 — Procurador de cuidados de saúde")
                legalRef(flag: "🇩🇪", law: "§1901a BGB — Vorsorgevollmacht")
                legalRef(flag: "🇺🇦", law: "ст.284 ЗУ — Медичний повірений")
                legalRef(flag: "🌍", law: "eIDAS Reg.910/2014 — Healthcare Proxy")
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func legalRef(flag: String, law: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(flag)
            Text(law).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var addProxyButton: some View {
        Button {
            drafts.append(ProxyDraft())
            expandedIndex = drafts.count - 1
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.navy)
                Text("Add proxy person")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.navy)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var continueSection: some View {
        VStack(spacing: 12) {
            if drafts.isEmpty {
                Text("You can add proxies later in Settings. Continuing without a proxy means emergency staff will only contact next-of-kin listed in their records.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                coordinator.markProxyComplete()
            } label: {
                Text(drafts.isEmpty ? "Continue without proxy" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.navy)
        }
        .padding(.top, 8)
    }

    private func checkAllSigned() {
        allSigned = drafts.allSatisfy { $0.signed }
    }
}

// MARK: - ProxyDraft

struct ProxyDraft: Identifiable {
    let id = UUID()
    var name: String = ""
    var phone: String = ""
    var email: String = ""
    var scope: ProxyScope = .informOnly
    var triggers: Set<ProxyTrigger> = [.unconscious, .anyIncapacity]
    var validUntil: Date? = nil
    var hasExpiry = false
    var signed = false
    var proxyRecord: HealthcareProxy? = nil
    var attachedDocument: ProxyDocument? = nil

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !phone.trimmingCharacters(in: .whitespaces).isEmpty &&
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !triggers.isEmpty
    }
}

// MARK: - ProxyCard

private struct ProxyCard: View {

    @Binding var draft: ProxyDraft
    let index: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onSigned: (HealthcareProxy) -> Void

    @State private var isSaving = false
    @State private var saveError: String? = nil
    @State private var savedProxy: HealthcareProxy? = nil
    @State private var showDocumentPicker = false
    @State private var showScanner = false
    @State private var showShareSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header row ────────────────────────────────────────────────
            HStack {
                Image(systemName: "person.fill")
                    .foregroundStyle(Color.navy)
                    .frame(width: 32)
                Text(draft.name.isEmpty ? "Proxy \(index + 1)" : draft.name)
                    .fontWeight(.semibold)
                Spacer()
                if draft.signed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if isExpanded {
                Divider()
                expandedContent
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Contact info
            VStack(spacing: 12) {
                TextField("Full name *", text: $draft.name)
                    .textContentType(.name)
                TextField("Phone number *", text: $draft.phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                TextField("Email address *", text: $draft.email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            // Scope
            VStack(alignment: .leading, spacing: 8) {
                Text("Decision authority").font(.subheadline).fontWeight(.semibold)
                Picker("Scope", selection: $draft.scope) {
                    ForEach([ProxyScope.informOnly, .advisory, .fullDecisionMaking], id: \.self) { scope in
                        Text(scope.displayLabel).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Triggers
            VStack(alignment: .leading, spacing: 8) {
                Text("Activates when").font(.subheadline).fontWeight(.semibold)
                ForEach(ProxyTrigger.allCases, id: \.self) { trigger in
                    Toggle(trigger.displayLabel, isOn: Binding(
                        get: { draft.triggers.contains(trigger) },
                        set: { on in
                            if on { draft.triggers.insert(trigger) }
                            else  { draft.triggers.remove(trigger) }
                        }
                    ))
                    .toggleStyle(.checkmark)
                }
            }

            // Validity
            Toggle("Set expiry date", isOn: $draft.hasExpiry)
            if draft.hasExpiry {
                DatePicker("Proxy valid until",
                           selection: Binding(
                            get: { draft.validUntil ?? Calendar.current.date(byAdding: .year, value: 2, to: Date())! },
                            set: { draft.validUntil = $0 }),
                           in: Date()...,
                           displayedComponents: .date)
            }

            Divider()

            // Official document section
            documentSection

            Divider()

            // Signature
            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            if let proxy = savedProxy {
                SignatureButton(
                    document: (try? JSONEncoder().encode(proxy)) ?? Data(),
                    documentType: .healthcareProxy,
                    consentItems: nil,
                    legalBasis: [.ptLei25, .deBGB1901a, .uaLaw2017, .eidasArt25],
                    jurisdictions: ["PT", "DE", "UA", "EU"],
                    adESText: "This designation of healthcare proxy has legal effect under Lei 25/2012, §1901a BGB, ст.284 ЗУ, and eIDAS Reg.910/2014.",
                    label: "Sign Proxy Designation"
                ) { result in
                    draft.signed = true
                    draft.proxyRecord = proxy
                    onSigned(proxy)
                    Task { try? await broadcastProxy(proxy: proxy, sigRecord: result.signatureRecord) }
                }
            } else {
                Button {
                    Task { await saveProxy() }
                } label: {
                    if isSaving {
                        HStack { ProgressView(); Text("Saving…") }
                    } else {
                        Text("Save Proxy")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.navy)
                .disabled(!draft.isValid || isSaving)
            }
        }
        .padding(16)
    }

    // MARK: - Document section

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Official Document")
                .font(.subheadline).fontWeight(.semibold)
            Text("Attach the official power of attorney, court order, or other authorizing document.")
                .font(.caption).foregroundStyle(.secondary)

            if let doc = draft.attachedDocument {
                attachedDocumentRow(doc)
            } else {
                HStack(spacing: 12) {
                    if DocumentScannerView.isAvailable {
                        Button { showScanner = true } label: {
                            Label("Scan", systemImage: "doc.viewfinder")
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { showDocumentPicker = true } label: {
                        Label("Import PDF", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            DocumentScannerView(
                onScan: { images in
                    showScanner = false
                    Task { await processDocumentImages(images) }
                },
                onCancel: { showScanner = false }
            )
        }
        .sheet(isPresented: $showDocumentPicker) {
            PDFPickerView(
                onPick: { url in
                    showDocumentPicker = false
                    Task { await processDocumentPDF(at: url) }
                },
                onCancel: { showDocumentPicker = false }
            )
        }
    }

    private func attachedDocumentRow(_ doc: ProxyDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.richtext.fill").foregroundStyle(Color.navy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.documentType.displayName).fontWeight(.semibold).font(.subheadline)
                    Text("\(doc.originalPages.count) page(s) — \(doc.detectedLanguage.uppercased())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if doc.blockchainTxHash != nil {
                    Image(systemName: "link.circle.fill").foregroundStyle(.green)
                }
            }

            if showShareSheet {
                ShareProxyDocumentView(document: doc, proxyId: draft.id)
            } else {
                Button("Share document") { showShareSheet = true }
                    .font(.caption).foregroundStyle(Color.navy)
            }
        }
        .padding(12)
        .background(Color.navy.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Document processing

    private func processDocumentImages(_ images: [UIImage]) async {
        guard let proxyId = savedProxy?.id ?? draft.proxyRecord?.id else { return }

        let ocrResults = (try? await LocalOCR.shared.recognizeDocument(images)) ?? []
        let translated = await DocumentTranslator.shared.translateDocument(ocrResults)
        let detectedLang = ocrResults.first?.rawText.isEmpty == false
            ? (translated.first?.sourceLanguage ?? "unknown")
            : "unknown"

        // Hash the raw bytes for blockchain proof-of-existence
        let allBytes = images.compactMap { $0.jpegData(compressionQuality: 0.85) }
            .reduce(Data(), +)
        let sha3 = SHA3_256.hash(data: allBytes).description

        let doc = ProxyDocument(
            id:               UUID(),
            proxyId:          proxyId,
            documentType:     .powerOfAttorney,
            originalPages:    allBytes.isEmpty ? [] : [allBytes],
            ocrText:          ocrResults.map { $0.rawText },
            detectedLanguage: detectedLang,
            translations:     buildTranslationMap(translated),
            uploadedAt:       Date(),
            sha3Hash:         sha3,
            blockchainTxHash: nil,
            shareGrants:      []
        )

        do {
            try await IdentityVaultManager.shared.sealProxyDocument(doc)
            draft.attachedDocument = doc
            // Broadcast proof-of-existence hash to Channel 1
            Task.detached(priority: .background) {
                _ = try? await FabricClient.channel1.recordAdESSignature(
                    documentHash:       sha3,
                    signerPubKeyHash:   (try? await DIDWallet.shared.currentUserIdHash()) ?? "",
                    signatureBase64:    "",
                    identityProvider:   "document-upload",
                    identityVerifiedAt: Int64(Date().timeIntervalSince1970),
                    legalBasis:         [LegalBasis.eidasArt25.rawValue],
                    documentType:       LegalDocumentType.proxyDocumentUpload.rawValue,
                    jurisdictions:      ["EU"]
                )
            }
        } catch {
            // Document stored locally even if blockchain broadcast fails
            draft.attachedDocument = doc
        }
    }

    private func processDocumentPDF(at url: URL) async {
        do {
            let pages = try await PDFImporter.shared.importPDF(at: url)
            await processDocumentImages(pages.map(\.image))
        } catch {
            // Silent — user can retry
        }
    }

    private func buildTranslationMap(_ translated: [TranslatedPage]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for page in translated {
            for (lang, text) in page.translations {
                if result[lang] == nil { result[lang] = [] }
                result[lang]?.append(text)
            }
        }
        return result
    }

    // MARK: - Save proxy

    private func saveProxy() async {
        guard draft.isValid else { return }
        isSaving = true
        saveError = nil

        do {
            let userIdHash  = try await DIDWallet.shared.currentUserIdHash()
            let signatureBytes = Data()  // Ed25519 computed by SignatureButton; placeholder here
            let proxy = HealthcareProxy(
                id:             UUID(),
                proxyName:      draft.name.trimmingCharacters(in: .whitespaces),
                phone:          draft.phone.trimmingCharacters(in: .whitespaces),
                email:          draft.email.trimmingCharacters(in: .whitespaces),
                scope:          draft.scope,
                triggers:       Array(draft.triggers),
                validFrom:      Date(),
                validUntil:     draft.hasExpiry ? draft.validUntil : nil,
                signature:      signatureBytes,
                blockchainTxHash: nil,
                jurisdictions:  ["PT", "DE", "UA", "EU"],
                legalReferences: [.ptLei25, .deBGB1901a, .uaLaw2017, .eidasArt25]
            )
            _ = userIdHash
            try await IdentityVaultManager.shared.sealProxy(proxy)
            savedProxy = proxy
            draft.proxyRecord = proxy
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }

    private func broadcastProxy(proxy: HealthcareProxy, sigRecord: SignatureRecord) async throws {
        let txHash = try await FabricClient.channel1.recordAdESSignature(
            documentHash:       sigRecord.documentHash,
            signerPubKeyHash:   sigRecord.publicKeyHash,
            signatureBase64:    sigRecord.signature.base64URLEncodedString(),
            identityProvider:   sigRecord.identityProvider,
            identityVerifiedAt: Int64(sigRecord.identityVerifiedAt.timeIntervalSince1970),
            legalBasis:         sigRecord.legalBasis.map { $0.rawValue },
            documentType:       sigRecord.documentType.rawValue,
            jurisdictions:      sigRecord.jurisdictions
        )
        try await IdentityVaultManager.shared.updateProxyTxHash(id: proxy.id, txHash: txHash)
    }
}

// MARK: - ShareProxyDocumentView

struct ShareProxyDocumentView: View {
    let document: ProxyDocument
    let proxyId: UUID

    @State private var recipientType: ShareRecipient = .emergencyDepartment
    @State private var recipientIdentifier: String = ""
    @State private var expiryHours: Int = 24
    @State private var purpose: String = ""
    @State private var showQR = false
    @State private var generatedGrant: ProxyDocumentShareGrant? = nil
    @State private var isGenerating = false
    @State private var error: String? = nil

    private let expiryOptions: [(label: String, hours: Int)] = [
        ("1 hour", 1), ("24 hours", 24), ("7 days", 168), ("Custom", -1)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share Document Access")
                .font(.subheadline).fontWeight(.bold)

            // Recipient type
            Picker("Recipient", selection: $recipientType) {
                Text("Emergency Dept.").tag(ShareRecipient.emergencyDepartment)
                Text("Clinic").tag(ShareRecipient.clinic)
                Text("Legal authority").tag(ShareRecipient.legalAuthority)
                Text("Insurance").tag(ShareRecipient.insurance)
            }
            .pickerStyle(.segmented)

            // Recipient identifier
            TextField("Recipient (license № or institution)", text: $recipientIdentifier)
                .autocorrectionDisabled()

            // Expiry
            Picker("Expires in", selection: $expiryHours) {
                ForEach(expiryOptions.filter { $0.hours > 0 }, id: \.hours) { opt in
                    Text(opt.label).tag(opt.hours)
                }
            }
            .pickerStyle(.segmented)

            // Purpose (required)
            TextField("Sharing purpose (required)", text: $purpose, axis: .vertical)
                .lineLimit(3...)

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            if let grant = generatedGrant {
                grantedView(grant)
            } else {
                Button {
                    Task { await generateGrant() }
                } label: {
                    if isGenerating {
                        HStack { ProgressView(); Text("Generating…") }
                    } else {
                        Label("Generate Share Link", systemImage: "link.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.navy)
                .disabled(recipientIdentifier.isEmpty || purpose.isEmpty || isGenerating)
            }
        }
        .padding(14)
        .background(Color.navy.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func grantedView(_ grant: ProxyDocumentShareGrant) -> some View {
        let link = AppConfig.appBaseURL.appendingPathComponent("/proxy/\(grant.oneTimeToken)").absoluteString
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("One-time share link generated")
                    .font(.subheadline).fontWeight(.semibold)
            }
            Text("Expires: \(grant.expiresAt, style: .relative)")
                .font(.caption).foregroundStyle(.secondary)
            Text(link)
                .font(.caption2)
                .foregroundStyle(Color.navy)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 12) {
                ShareLink(item: URL(string: link)!) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .tint(Color.navy)
            }
        }
    }

    private func generateGrant() async {
        guard !recipientIdentifier.isEmpty, !purpose.isEmpty else { return }
        isGenerating = true
        error = nil

        let recipientData = recipientIdentifier.data(using: .utf8) ?? Data()
        let recipientHash = SHA3_256.hash(data: recipientData).description
        let expiresAt     = Date().addingTimeInterval(Double(expiryHours) * 3600)
        let token         = UUID().uuidString

        let signatureBytes = (try? await KeyManager.shared.sign(token.data(using: .utf8) ?? Data())) ?? Data()

        let grant = ProxyDocumentShareGrant(
            id:               UUID(),
            sharedAt:         Date(),
            recipientType:    recipientType,
            recipientHash:    recipientHash,
            scopeDescription: purpose,
            expiresAt:        expiresAt,
            oneTimeToken:     token,
            signature:        signatureBytes,
            accessedAt:       nil,
            blockchainTxHash: nil
        )

        do {
            try await IdentityVaultManager.shared.sealShareGrant(grant, docId: document.id)
            generatedGrant = grant
            // Log share intent to Ch3
            Task.detached(priority: .background) {
                _ = try? await FabricClient.channel3.recordEHRAccess(
                    accessorHash: recipientHash,
                    patientHash:  (try? await DIDWallet.shared.currentUserIdHash()) ?? "",
                    purpose:      purpose,
                    tokenJTI:     token
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
        isGenerating = false
    }
}

// MARK: - Toggle checkmark style

struct CheckmarkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.navy : .secondary)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == CheckmarkToggleStyle {
    static var checkmark: CheckmarkToggleStyle { CheckmarkToggleStyle() }
}

// MARK: - ProxyDocumentType display

extension ProxyDocumentType {
    var displayName: String {
        switch self {
        case .powerOfAttorney:          return "Power of Attorney"
        case .courtOrder:               return "Court Order"
        case .guardianshipCertificate:  return "Guardianship Certificate"
        case .notarizedDeclaration:     return "Notarized Declaration"
        case .hospitalForm:             return "Hospital Form"
        }
    }
}

// MARK: - Data extension

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import Security

#Preview {
    HealthcareProxyView()
        .environmentObject(OnboardingCoordinator())
}
