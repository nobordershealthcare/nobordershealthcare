// DataAuthorizationView.swift — Step 6: GDPR Art.28 Data Processing Agreement.
//
// This view collects the patient's data processing authorization:
//   Section 1 — Receive data FROM (4 sources)
//   Section 2 — Storage permissions (3 options)
//   Section 3 — Transfer data TO (3 recipient types + custom institutions)
//   Section 4 — Processing purposes (4 purposes)
//   Governing law (EU GDPR required; national laws optional)
//   Valid until (DatePicker or indefinite)
//
// SignatureButton signs the full DataProcessingAuthorization with:
//   legalBasis: [.gdprArt7, .gdprArt9, .eidasArt25, .uaLaw2017]
//
// After sign: LegalVaultManager.sealDataProcessingAuth() → Ch1 → Ch2.

import SwiftUI

// MARK: - DataAuthorizationView

struct DataAuthorizationView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator

    // Section 1 — Data sources
    @State private var receiveUkraine  = false
    @State private var receiveGermany  = false
    @State private var receivePortugal = false
    @State private var specificClinics: [SpecificClinic] = []
    @State private var showAddClinic   = false

    // Section 2 — Storage
    @State private var storeOnDevice  = true   // default: on-device only (required for app function)
    @State private var storeEUCloud   = false
    @State private var storeP2P       = false

    // Section 3 — Recipients
    @State private var transferToED    = false
    @State private var transferToProxy = false
    @State private var customRecipients: [CustomRecipient] = []
    @State private var showAddRecipient = false

    // Section 4 — Purposes
    @State private var purposeEmergency    = true   // always selected (core service)
    @State private var purposeTranslation  = false
    @State private var purposeSummary      = false
    @State private var purposeIPS          = false

    // Governing law
    @State private var lawUkraine   = false
    @State private var lawPortugal  = false
    @State private var lawGermany   = false

    // Validity
    @State private var isIndefinite = true
    @State private var validUntil: Date = Calendar.current.date(byAdding: .year, value: 2, to: Date())!

    // Signing state
    @State private var authSigned = false

    var body: some View {
        NavigationStack {
            Form {
                receiveSection
                storageSection
                transferSection
                purposeSection
                governingLawSection
                validitySection
                signatureSection
            }
            .navigationTitle("Data Authorization")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showAddClinic) {
            addClinicSheet
        }
        .sheet(isPresented: $showAddRecipient) {
            addRecipientSheet
        }
    }

    // MARK: - Section 1: Receive FROM

    private var receiveSection: some View {
        Section {
            Toggle("Ukrainian national eHealth system (МОЗ API)", isOn: $receiveUkraine)
            Toggle("German EPA (elektronische Patientenakte)", isOn: $receiveGermany)
            Toggle("Portuguese SNS (Serviço Nacional de Saúde)", isOn: $receivePortugal)

            ForEach($specificClinics) { $clinic in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clinic.name).font(.subheadline)
                        Text("\(clinic.country) · \(clinic.identifier)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        specificClinics.removeAll { $0.id == clinic.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                showAddClinic = true
            } label: {
                Label("Add specific clinic", systemImage: "plus.circle")
                    .foregroundStyle(Color.navy)
            }
        } header: {
            Text("Receive Medical Data From")
        } footer: {
            Text("Authorizes the platform to accept data sent by these sources on your behalf.")
        }
    }

    // MARK: - Section 2: Storage

    private var storageSection: some View {
        Section {
            HStack {
                Toggle("Encrypted on-device storage", isOn: $storeOnDevice)
                    .disabled(true)  // Always required for app function
            }
            Toggle("Encrypted EU cloud backup", isOn: $storeEUCloud)
            Toggle("Encrypted P2P distributed backup (IPFS + Shamir)", isOn: $storeP2P)
        } header: {
            Text("Storage Permissions")
        } footer: {
            Text("On-device storage cannot be disabled — it is required for the app to function.")
        }
    }

    // MARK: - Section 3: Transfer TO

    private var transferSection: some View {
        Section {
            Toggle("Emergency department clinicians (via QR, time-limited)", isOn: $transferToED)
            Toggle("My designated healthcare proxy", isOn: $transferToProxy)

            ForEach($customRecipients) { $recipient in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipient.name).font(.subheadline)
                        Text("\(recipient.country) · \(recipient.purpose)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        customRecipients.removeAll { $0.id == recipient.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                showAddRecipient = true
            } label: {
                Label("Add specific institution", systemImage: "plus.circle")
                    .foregroundStyle(Color.navy)
            }
        } header: {
            Text("Transfer Data To")
        } footer: {
            Text("Emergency QR sharing is always time-limited (15-minute JWT) and logged.")
        }
    }

    // MARK: - Section 4: Purposes

    private var purposeSection: some View {
        Section {
            HStack {
                Toggle("Rendering emergency medical assistance", isOn: $purposeEmergency)
                    .disabled(true)  // Core service
            }
            Toggle("Medical document translation", isOn: $purposeTranslation)
            Toggle("Generating medical summaries (FHIR IPS)", isOn: $purposeSummary)
            Toggle("Building International Patient Summary", isOn: $purposeIPS)
        } header: {
            Text("Processing Purposes")
        } footer: {
            Text("Emergency medical assistance cannot be deselected — it is the core service purpose.")
        }
    }

    // MARK: - Governing law

    private var governingLawSection: some View {
        Section {
            HStack {
                Toggle("EU GDPR (Regulation 2016/679)", isOn: .constant(true))
                    .disabled(true)  // Always applies
            }
            Toggle("Ukrainian Personal Data Protection Law (2010)", isOn: $lawUkraine)
            Toggle("Portuguese RGPD (Lei 58/2019)", isOn: $lawPortugal)
            Toggle("German BDSG (Bundesdatenschutzgesetz)", isOn: $lawGermany)
        } header: {
            Text("Governing Law")
        } footer: {
            Text("EU GDPR always applies. Select additional national laws that govern your specific situation.")
        }
    }

    // MARK: - Validity

    private var validitySection: some View {
        Section {
            Toggle("Indefinite (until revoked)", isOn: $isIndefinite)
            if !isIndefinite {
                DatePicker("Valid until",
                           selection: $validUntil,
                           in: Date()...,
                           displayedComponents: .date)
            }
        } header: {
            Text("Authorization Period")
        }
    }

    // MARK: - Signature

    private var signatureSection: some View {
        Section {
            if authSigned {
                HStack {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                    Text("Authorization signed and sealed")
                        .fontWeight(.semibold)
                }
                Button {
                    coordinator.markDataAuthComplete()
                } label: {
                    Text("Complete Setup")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.navy)
            } else {
                SignatureButton(
                    document: buildAuthorizationDocument(),
                    documentType: .dataProcessingAuth,
                    consentItems: nil,
                    legalBasis: [.gdprArt7, .gdprArt9, .eidasArt25, .uaLaw2017],
                    jurisdictions: governingJurisdictions,
                    adESText: "This authorization has the legal force of a Data Processing Agreement (GDPR Art.28) and an Advanced Electronic Signature (eIDAS Art.25). You may withdraw this authorization anytime in Settings.",
                    label: "Sign Data Processing Authorization"
                ) { result in
                    authSigned = true
                    Task { await storeAuthorization(result: result) }
                }
            }
        } header: {
            Text("Sign & Finalize")
        }
    }

    // MARK: - Build authorization model

    private var governingJurisdictions: [String] {
        var j = ["EU"]
        if lawUkraine  { j.append("UA") }
        if lawPortugal { j.append("PT") }
        if lawGermany  { j.append("DE") }
        return j
    }

    private var governingLawStrings: [String] {
        var laws = ["EU-GDPR"]
        if lawUkraine  { laws.append("UA-2021") }
        if lawPortugal { laws.append("PT-RGPD") }
        if lawGermany  { laws.append("DE-BDSG") }
        return laws
    }

    private func buildDataSources() -> [DataSource] {
        var sources: [DataSource] = []
        if receiveUkraine  { sources.append(.ukraineEHealth) }
        if receiveGermany  { sources.append(.germanEPA) }
        if receivePortugal { sources.append(.portugueseSNS) }
        if !specificClinics.isEmpty { sources.append(.specificClinic) }
        return sources
    }

    private func buildStoragePermissions() -> [StoragePermission] {
        var perms: [StoragePermission] = [.onDevice]
        if storeEUCloud { perms.append(.euCloud) }
        if storeP2P     { perms.append(.p2pDistributed) }
        return perms
    }

    private func buildRecipients() -> [DataRecipient] {
        var recipients: [DataRecipient] = []
        if transferToED {
            recipients.append(DataRecipient(id: UUID(), type: .emergencyDepartment,
                                            name: "Emergency Department", country: "EU",
                                            purpose: "Emergency medical care via QR code"))
        }
        if transferToProxy {
            recipients.append(DataRecipient(id: UUID(), type: .healthcareProxy,
                                            name: "Designated Healthcare Proxy", country: "EU",
                                            purpose: "Medical decisions when patient incapacitated"))
        }
        for cr in customRecipients {
            recipients.append(DataRecipient(id: cr.id, type: .specificInstitution,
                                            name: cr.name, country: cr.country,
                                            purpose: cr.purpose))
        }
        return recipients
    }

    private func buildProcessingPurposes() -> [ProcessingPurpose] {
        var purposes: [ProcessingPurpose] = [.emergencyAssistance]
        if purposeTranslation { purposes.append(.documentTranslation) }
        if purposeSummary     { purposes.append(.medicalSummary) }
        if purposeIPS         { purposes.append(.ipsGeneration) }
        return purposes
    }

    private func buildAuthorizationDocument() -> Data {
        let placeholder = DataProcessingAuthorization(
            id: UUID(), grantorHash: "", grantee: "nobordershealthcare-platform",
            receiveFrom: buildDataSources(),
            storagePermissions: buildStoragePermissions(),
            transferTo: buildRecipients(),
            processingPurposes: buildProcessingPurposes(),
            validFrom: Date(),
            validUntil: isIndefinite ? nil : validUntil,
            governingLaw: governingLawStrings,
            signature: Data(),
            blockchainTxHash: nil
        )
        return (try? JSONEncoder().encode(placeholder)) ?? Data()
    }

    private func storeAuthorization(result: SigningResult) async {
        do {
            let userIdHash = try await DIDWallet.shared.currentUserIdHash()
            let auth = DataProcessingAuthorization(
                id:                  UUID(),
                grantorHash:         userIdHash,
                grantee:             "nobordershealthcare-platform",
                receiveFrom:         buildDataSources(),
                storagePermissions:  buildStoragePermissions(),
                transferTo:          buildRecipients(),
                processingPurposes:  buildProcessingPurposes(),
                validFrom:           Date(),
                validUntil:          isIndefinite ? nil : validUntil,
                governingLaw:        governingLawStrings,
                signature:           result.signatureRecord.signature,
                blockchainTxHash:    nil
            )
            try await LegalVaultManager.shared.sealDataProcessingAuth(auth)
        } catch {
            // Sealed locally in SignatureButton; non-fatal if this call fails
        }
    }

    // MARK: - Add clinic sheet

    private var addClinicSheet: some View {
        AddItemSheet(title: "Add Clinic") { name, country, id in
            specificClinics.append(SpecificClinic(name: name, country: country, identifier: id))
            showAddClinic = false
        } onCancel: {
            showAddClinic = false
        }
    }

    private var addRecipientSheet: some View {
        AddItemSheet(title: "Add Institution") { name, country, purpose in
            customRecipients.append(CustomRecipient(name: name, country: country, purpose: purpose))
            showAddRecipient = false
        } onCancel: {
            showAddRecipient = false
        }
    }
}

// MARK: - Supporting types

private struct SpecificClinic: Identifiable {
    let id = UUID()
    var name: String
    var country: String
    var identifier: String
}

private struct CustomRecipient: Identifiable {
    let id = UUID()
    var name: String
    var country: String
    var purpose: String
}

// MARK: - AddItemSheet (reusable)

private struct AddItemSheet: View {
    let title: String
    let onAdd: (String, String, String) -> Void
    let onCancel: () -> Void

    @State private var name     = ""
    @State private var country  = ""
    @State private var thirdField = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Institution name", text: $name)
                TextField("Country (ISO code, e.g. DE)", text: $country)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("ID / License / Purpose", text: $thirdField)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") { onAdd(name, country, thirdField) }
                        .disabled(name.isEmpty || country.isEmpty || thirdField.isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    DataAuthorizationView()
        .environmentObject(OnboardingCoordinator())
}
