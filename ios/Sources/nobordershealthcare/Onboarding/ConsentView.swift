// ConsentView.swift — Step 5: Explicit GDPR Article 9 consent for each data type.
//
// 12 ConsentScopeItem toggles — 2 required (localStorage, emergencyAccess).
// Each item is expandable with legal explanation.
// SignatureButton signs the entire ConsentRecord as ONE atomic Ed25519 signature.
//
// GDPR requirements implemented:
//   Art.7: freely given, specific, informed, unambiguous
//   Art.9: explicit consent for special-category health data
//   Art.7(3): "You can revoke any consent anytime in Settings"
//
// After sign: LegalVaultManager.sealConsent() → Ch1 → Ch2.

import SwiftUI

// MARK: - ConsentView

struct ConsentView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @State private var scopeItems: [ConsentScopeItem] = ConsentView.buildDefaultItems()
    @State private var expandedItemId: UUID? = nil
    @State private var showFullLegalSheet = false
    @State private var signingDocument: Data? = nil
    @State private var consentSigned = false

    private var requiredItemsGranted: Bool {
        scopeItems.filter { $0.required }.allSatisfy { $0.granted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    consentList
                    revocationNotice
                    signatureSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .navigationTitle("Data Consent")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showFullLegalSheet) {
            fullLegalTextSheet
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data Processing Consent")
                .font(.title3).fontWeight(.bold)
            Text("(GDPR Article 9)")
                .font(.subheadline).foregroundStyle(Color.navy)
            Text("Health data is special-category personal data. Each type requires your explicit, separate consent. Items marked ✳ are required to use this app. You can change all optional consents anytime in Settings.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var consentList: some View {
        VStack(spacing: 10) {
            ForEach($scopeItems) { $item in
                ConsentItemCard(
                    item: $item,
                    isExpanded: expandedItemId == item.id,
                    onToggleExpand: {
                        withAnimation(.spring(duration: 0.25)) {
                            expandedItemId = (expandedItemId == item.id) ? nil : item.id
                        }
                    },
                    onShowFullText: { showFullLegalSheet = true }
                )
            }
        }
    }

    private var revocationNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.navy)
            Text("You can revoke any consent anytime in Settings → Privacy → Consent Management. Revocation is immediate, permanent-until-re-granted, and logged on the blockchain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.navy.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var signatureSection: some View {
        VStack(spacing: 16) {
            if consentSigned {
                HStack {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                    Text("Consent signed and sealed")
                        .fontWeight(.semibold)
                }
                Button {
                    coordinator.markConsentComplete()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.navy)
            } else {
                SignatureButton(
                    document: buildConsentDocument(),
                    documentType: .gdprConsent,
                    consentItems: scopeItems,
                    legalBasis: [.gdprArt9, .gdprArt7],
                    jurisdictions: ["EU"],
                    adESText: "By signing I provide explicit consent under GDPR Art.9 for processing of my special-category health data as described above. Each consent item is independently recorded.",
                    label: "Sign Consent"
                ) { _ in
                    consentSigned = true
                    // Coordinator advanced by the "Continue" button below,
                    // matching the pattern used in all other onboarding steps.
                }
                .disabled(!requiredItemsGranted)

                if !requiredItemsGranted {
                    Text("The two required items (marked ✳) must be enabled to continue.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Helpers

    private func buildConsentDocument() -> Data {
        var currentItems = scopeItems
        for i in currentItems.indices where currentItems[i].granted {
            currentItems[i].grantedAt = Date()
        }
        return (try? JSONEncoder().encode(currentItems)) ?? Data()
    }

    private var fullLegalTextSheet: some View {
        NavigationStack {
            ScrollView {
                Text(fullLegalText)
                    .font(.caption)
                    .padding(20)
            }
            .navigationTitle("Full Legal Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showFullLegalSheet = false }
                }
            }
        }
    }

    private let fullLegalText = """
    GDPR Regulation (EU) 2016/679 — Data Processing Consent

    Article 7 — Conditions for consent:
    1. Where processing is based on consent, the controller shall be able to demonstrate that the data subject has consented to processing of his or her personal data.
    4. When assessing whether consent is freely given, utmost account shall be taken of whether, inter alia, the performance of a contract, including the provision of a service, is conditional on consent to the processing of personal data that is not necessary for the performance of that contract.

    Article 9 — Processing of special categories of personal data:
    1. Processing of personal data revealing racial or ethnic origin, political opinions, religious or philosophical beliefs, or trade union membership, and the processing of genetic data, biometric data for the purpose of uniquely identifying a natural person, data concerning health or data concerning a natural person's sex life or sexual orientation shall be prohibited.
    2(a). The data subject has given explicit consent to the processing of those personal data for one or more specified purposes, except where Union or Member State law provide that the prohibition referred to in paragraph 1 may not be lifted by the data subject.

    eIDAS Regulation (EU) 910/2014 — Article 25:
    An electronic signature shall not be denied legal effect and admissibility as evidence in legal proceedings solely on the grounds that it is in an electronic form or that it does not meet the requirements for qualified electronic signatures.
    """

    // MARK: - Default items builder

    static func buildDefaultItems() -> [ConsentScopeItem] {
        [
            ConsentScopeItem(
                id: UUID(), type: .localStorage, required: true,
                titleKey: "consent.localStorage.title",
                descriptionKey: "consent.localStorage.desc",
                legalBasis: [.gdprArt9],
                granted: true, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .emergencyAccess, required: true,
                titleKey: "consent.emergencyAccess.title",
                descriptionKey: "consent.emergencyAccess.desc",
                legalBasis: [.gdprArt9, .euMDR],
                granted: true, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .cloudBackup, required: false,
                titleKey: "consent.cloudBackup.title",
                descriptionKey: "consent.cloudBackup.desc",
                legalBasis: [.gdprArt9],
                granted: false, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .p2pBackup, required: false,
                titleKey: "consent.p2pBackup.title",
                descriptionKey: "consent.p2pBackup.desc",
                legalBasis: [.gdprArt9],
                granted: false, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .proxyAccess, required: false,
                titleKey: "consent.proxyAccess.title",
                descriptionKey: "consent.proxyAccess.desc",
                legalBasis: [.gdprArt9, .ptLei25],
                granted: false, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .crossBorderEU, required: false,
                titleKey: "consent.crossBorderEU.title",
                descriptionKey: "consent.crossBorderEU.desc",
                legalBasis: [.gdprArt9],
                granted: false, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .crossBorderUkraine, required: false,
                titleKey: "consent.crossBorderUkraine.title",
                descriptionKey: "consent.crossBorderUkraine.desc",
                legalBasis: [.gdprArt9, .uaLaw2017],
                granted: false, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .researchAnonymized, required: false,
                titleKey: "consent.research.title",
                descriptionKey: "consent.research.desc",
                legalBasis: [.gdprArt9],
                granted: false, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .dataReceiptFromClinics, required: false,
                titleKey: "consent.dataReceipt.title",
                descriptionKey: "consent.dataReceipt.desc",
                legalBasis: [.gdprArt9],
                granted: false, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .dataTransferToClinics, required: false,
                titleKey: "consent.dataTransfer.title",
                descriptionKey: "consent.dataTransfer.desc",
                legalBasis: [.gdprArt9],
                granted: false, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .clinicianVerification, required: false,
                titleKey: "consent.clinicianVerif.title",
                descriptionKey: "consent.clinicianVerif.desc",
                legalBasis: [.gdprArt9],
                granted: false, grantedAt: nil, revokedAt: nil
            ),
            ConsentScopeItem(
                id: UUID(), type: .documentTranslation, required: false,
                titleKey: "consent.docTranslation.title",
                descriptionKey: "consent.docTranslation.desc",
                legalBasis: [.gdprArt9],
                granted: false, grantedAt: nil, revokedAt: nil
            ),
        ]
    }
}

// MARK: - ConsentItemCard

private struct ConsentItemCard: View {
    @Binding var item: ConsentScopeItem
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onShowFullText: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { item.granted },
                    set: { newVal in
                        if item.required && !newVal { return }  // required items cannot be disabled
                        item.granted = newVal
                        item.grantedAt = newVal ? Date() : nil
                    }
                ))
                .labelsHidden()
                .tint(Color.navy)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(localizedTitle(item.titleKey))
                            .font(.subheadline).fontWeight(.semibold)
                        if item.required {
                            Text("✳")
                                .font(.caption)
                                .foregroundStyle(Color.navy)
                        }
                    }
                    Text(item.legalBasis.map { shortLabel($0) }.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onToggleExpand) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Text(localizedDescription(item.descriptionKey))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                    Button("Read full legal text →", action: onShowFullText)
                        .font(.caption).foregroundStyle(Color.navy)
                        .padding(.horizontal, 14)
                }
                .padding(.bottom, 12)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(item.required ? Color.navy.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private func shortLabel(_ basis: LegalBasis) -> String {
        switch basis {
        case .gdprArt9:   return "GDPR Art.9"
        case .gdprArt7:   return "GDPR Art.7"
        case .eidasArt25: return "eIDAS Art.25"
        case .uaLaw2017:  return "UA Law"
        case .ptLei25:    return "PT Lei 25/2012"
        case .deBGB1901a: return "DE §1901a BGB"
        case .euMDR:      return "EU MDR"
        }
    }

    // Inline localized strings — for production, move to Localizable.strings
    private func localizedTitle(_ key: String) -> String {
        let titles: [String: String] = [
            "consent.localStorage.title":    "Store emergency data on this device",
            "consent.emergencyAccess.title": "Allow emergency QR code access",
            "consent.cloudBackup.title":     "Encrypted cloud backup (EU servers)",
            "consent.p2pBackup.title":       "Encrypted P2P backup (IPFS)",
            "consent.proxyAccess.title":     "Healthcare proxy access",
            "consent.crossBorderEU.title":   "Transfer data within EU",
            "consent.crossBorderUkraine.title": "Transfer data to Ukraine",
            "consent.research.title":        "Anonymized research use",
            "consent.dataReceipt.title":     "Receive medical data from clinics",
            "consent.dataTransfer.title":    "Send medical data to clinics",
            "consent.clinicianVerif.title":  "Clinician identity verification",
            "consent.docTranslation.title":  "Document translation",
        ]
        return titles[key] ?? key
    }

    private func localizedDescription(_ key: String) -> String {
        let descs: [String: String] = [
            "consent.localStorage.desc":    "Your emergency health data is stored encrypted on this device using AES-256 with a Secure Enclave key. Required to use the app.",
            "consent.emergencyAccess.desc": "Emergency doctors can scan your QR code to see critical information. The QR expires every 15 minutes and is self-verifying offline. Required.",
            "consent.cloudBackup.desc":     "An encrypted backup is stored on EU-based servers. Only you hold the decryption key. Useful if you lose your device.",
            "consent.p2pBackup.desc":       "Your encrypted data is split into 7 shards using Shamir Secret Sharing (K=3 required for recovery) distributed across the IPFS network.",
            "consent.proxyAccess.desc":     "Your designated healthcare proxy can access your emergency data when you are incapacitated, as specified in your proxy designation.",
            "consent.crossBorderEU.desc":   "Allows transferring your data to healthcare providers in EU Member States under GDPR Article 44 data transfer provisions.",
            "consent.crossBorderUkraine.title": "Allows transferring data to Ukraine under GDPR Article 46 appropriate safeguards (standard contractual clauses).",
            "consent.research.desc":        "Allows using fully anonymized data (no identifiers, no hashes) for medical research. Your data is never re-identifiable in this context.",
            "consent.dataReceipt.desc":     "Allows clinics to send your medical records to this app on your behalf, such as after a hospital visit.",
            "consent.dataTransfer.desc":    "Allows this app to send your emergency data to clinics you explicitly authorize, for continuity of care.",
            "consent.clinicianVerif.desc":  "Allows logging clinician license numbers when they access your emergency QR, for your protection and accountability.",
            "consent.docTranslation.desc":  "Allows on-device translation of your medical documents using local AI models (opus-mt). No data leaves the device.",
        ]
        return descs[key] ?? key
    }
}

#Preview {
    ConsentView()
        .environmentObject(OnboardingCoordinator())
}
