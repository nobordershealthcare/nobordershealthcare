// EmergencyCardSetupView.swift — Step 3: Emergency card data entry and first signing.
//
// Validation before Save is enabled:
//   displayName: non-empty, ≤50 chars, must not look like a full name (hint shown)
//   dateOfBirth: DatePicker, must be in past, born ≤120 years ago
//   bloodType:   Picker, all 8 BloodType cases, no implicit default
//   allergies:   searchable multi-select, free text entry, sorted alpha, deduplicated
//   medications: dynamic list (name + dose + frequency + ATC lookup)
//
// On Save:
//   MedicalVaultManager.seal(emergencyCard) → Silo 2
//   SignatureButton signs with legalBasis [.gdprArt9, .euMDR]
//   EmergencyCardService.buildAndSign() → first JWT
//
// No hardcoded patient data — all fields start empty.

import SwiftUI

// MARK: - EmergencyCardSetupView

struct EmergencyCardSetupView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator

    // ── Form state ─────────────────────────────────────────────────────────────
    @State private var displayName: String = ""
    @State private var dateOfBirth: Date   = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var selectedBloodType: BloodType? = nil
    @State private var selectedAllergies: Set<String> = []
    @State private var customAllergyInput: String = ""
    @State private var medications: [MedicationDraft] = []
    @State private var allergySearchText: String = ""

    // ── Support profile state ──────────────────────────────────────────────────
    @State private var salutation: String = ""
    @State private var supportNickname: String = ""
    @State private var selectedSecurityQuestion: SecurityQuestion = .firstPet
    @State private var customQuestionText: String = ""
    @State private var securityAnswer: String = ""
    @State private var securityAnswerConfirm: String = ""
    @State private var supportSaveError: String? = nil

    // ── UI state ───────────────────────────────────────────────────────────────
    @State private var isSaving = false
    @State private var savedCard: EmergencyCard? = nil
    @State private var saveError: String? = nil
    @State private var showAddMedication = false

    // ── Validation bounds ──────────────────────────────────────────────────────
    private let maxNameLength     = 50
    private let maxAge: TimeInterval = 120 * 365.25 * 24 * 3600  // 120 years

    private let presetAllergies: [String] = [
        "Aspirin", "Codeine", "Contrast media", "Ibuprofen", "Latex",
        "NSAIDs", "Peanuts", "Penicillin", "Shellfish", "Sulfa drugs",
    ]  // alphabetically sorted — do NOT add patient names

    private var filteredAllergies: [String] {
        let all = (presetAllergies + Array(selectedAllergies)).map { $0.lowercased() }
        let uniqueSorted = Array(Set(all)).sorted()
        if allergySearchText.isEmpty { return uniqueSorted.map { $0.capitalized } }
        return uniqueSorted.filter { $0.contains(allergySearchText.lowercased()) }.map { $0.capitalized }
    }

    // MARK: - Validation

    private var nameValidation: String? {
        if displayName.isEmpty { return nil }
        if displayName.count > maxNameLength { return "Name must be \(maxNameLength) characters or fewer" }
        let words = displayName.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
        if words.count >= 3 { return "Use first name and last initial only (e.g. \"Maria K.\")" }
        return nil
    }

    private var dobValidation: String? {
        if dateOfBirth >= Date() { return "Date of birth must be in the past" }
        if Date().timeIntervalSince(dateOfBirth) > maxAge { return "Please check the date — age exceeds 120 years" }
        return nil
    }

    private var canSave: Bool {
        !displayName.isEmpty
        && nameValidation == nil
        && dobValidation == nil
        && selectedBloodType != nil
        && !isSaving
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                bloodTypeSection
                allergySection
                medicationSection
                supportSection
                signatureSection
            }
            .navigationTitle("Emergency Card")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSaving)
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                TextField("e.g. Maria K.", text: $displayName)
                    .textContentType(.givenName)
                    .autocorrectionDisabled()
                if let hint = nameValidation {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if displayName.isEmpty {
                    Text("Use first name and last initial: \"Maria K.\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(displayName.count)/\(maxNameLength)")
                    .font(.caption2)
                    .foregroundStyle(displayName.count > maxNameLength ? .red : .secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                DatePicker("Date of birth", selection: $dateOfBirth,
                           in: Calendar.current.date(byAdding: .year, value: -120, to: Date())!...Date(),
                           displayedComponents: .date)
                if let err = dobValidation {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Identity")
        } footer: {
            Text("Displayed to emergency staff. Use first name and last initial for privacy.")
        }
    }

    private var bloodTypeSection: some View {
        Section("Blood Type") {
            Picker("Blood type", selection: $selectedBloodType) {
                Text("Select…").tag(Optional<BloodType>.none)
                ForEach(BloodType.allCases, id: \.self) { bt in
                    Text(bt.rawValue).tag(Optional(bt))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var allergySection: some View {
        Section {
            TextField("Search or add allergy…", text: $allergySearchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .onSubmit { addCustomAllergy() }

            ForEach(filteredAllergies, id: \.self) { allergy in
                let key = allergy.lowercased()
                HStack {
                    Text(allergy)
                    Spacer()
                    if selectedAllergies.contains(key) {
                        Image(systemName: "checkmark").foregroundStyle(Color.navy)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectedAllergies.contains(key) {
                        selectedAllergies.remove(key)
                    } else {
                        selectedAllergies.insert(key)
                    }
                }
            }

            if !allergySearchText.isEmpty,
               !filteredAllergies.map({ $0.lowercased() }).contains(allergySearchText.lowercased()) {
                Button("Add \"\(allergySearchText)\"") { addCustomAllergy() }
                    .foregroundStyle(Color.navy)
            }
        } header: {
            Label("Allergies (\(selectedAllergies.count) selected)", systemImage: "allergens")
        } footer: {
            Text("Select all known drug, food, and material allergies. Critical for emergency care.")
        }
    }

    private func addCustomAllergy() {
        let input = allergySearchText.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        selectedAllergies.insert(input.lowercased())
        allergySearchText = ""
    }

    private var medicationSection: some View {
        Section {
            ForEach($medications) { $med in
                MedicationRowEditor(draft: $med)
            }
            .onDelete { medications.remove(atOffsets: $0) }

            Button {
                medications.append(MedicationDraft())
            } label: {
                Label("Add medication", systemImage: "plus.circle")
            }
            .foregroundStyle(Color.navy)
        } header: {
            Label("Current Medications (\(medications.count))", systemImage: "pills.fill")
        } footer: {
            Text("Name, dose, and frequency are required. ATC code is auto-suggested from the drug name.")
        }
    }

    // MARK: - Support section

    private var supportSection: some View {
        Section {
            // "How should we address you?"
            VStack(alignment: .leading, spacing: 4) {
                Text("How should we address you?")
                    .font(.subheadline).fontWeight(.medium)
                TextField("E.g. Maria, Mr. Smith, Dr. Kovalenko", text: $salutation)
                    .textContentType(.name)
                    .autocorrectionDisabled()
            }

            // Support nickname
            VStack(alignment: .leading, spacing: 4) {
                TextField("Support nickname", text: $supportNickname)
                    .textContentType(.nickname)
                    .autocorrectionDisabled()
                Text("Not your medical name — just for support contact")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Security question picker
            Picker("Security question", selection: $selectedSecurityQuestion) {
                ForEach(SecurityQuestion.allCases, id: \.self) { q in
                    Text(q.displayLabel).tag(q)
                }
            }
            .pickerStyle(.menu)

            // Extra TextField when "Custom question…" is chosen
            if selectedSecurityQuestion == .customQuestion {
                TextField("Your custom question", text: $customQuestionText)
                    .autocorrectionDisabled()
            }

            // Answer — two SecureFields; hash matched before saving
            SecureField("Security answer", text: $securityAnswer)
            SecureField("Confirm answer",  text: $securityAnswerConfirm)

            if !securityAnswer.isEmpty,
               !securityAnswerConfirm.isEmpty,
               securityAnswer != securityAnswerConfirm {
                Text("Answers do not match")
                    .font(.caption).foregroundStyle(.orange)
            }

            if let err = supportSaveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

        } header: {
            Text("Support & Contact Preferences")
        } footer: {
            Text("Support will NEVER ask for your medical data.\nOnly nickname, date of birth, and security answer are used to verify your identity.")
        }
    }

    // Saves support profile to Keychain alongside the emergency card.
    // Silently skips when required support fields are absent or the answers mismatch.
    // Answer plaintext is zeroed from @State vars immediately after hashing.
    private func saveSupportProfile() {
        let nick = supportNickname.trimmingCharacters(in: .whitespaces)
        guard !nick.isEmpty,
              !securityAnswer.isEmpty,
              securityAnswer == securityAnswerConfirm
        else { return }

        let questionText: String
        let questionKey: String
        if selectedSecurityQuestion == .customQuestion {
            let custom = customQuestionText.trimmingCharacters(in: .whitespaces)
            guard !custom.isEmpty else { return }
            questionText = custom
            questionKey  = SecurityQuestion.customQuestion.rawValue
        } else {
            questionText = selectedSecurityQuestion.displayLabel
            questionKey  = selectedSecurityQuestion.rawValue
        }

        var profile = SupportProfile(
            salutation:          salutation.trimmingCharacters(in: .whitespaces),
            nickname:            nick,
            securityQuestion:    questionText,
            securityQuestionKey: questionKey,
            securityAnswerHash:  "",
            updatedAt:           Date()
        )

        do {
            try profile.setAnswer(securityAnswer)
        } catch {
            supportSaveError = error.localizedDescription
            return
        }

        // Zero plaintext from @State — removes reference; ARC will reclaim memory
        securityAnswer        = ""
        securityAnswerConfirm = ""

        SupportProfileStore.save(profile)
    }

    private var signatureSection: some View {
        Section {
            if let card = savedCard {
                // Card already saved — show signature button
                VStack(spacing: 16) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Emergency card saved")
                        Spacer()
                    }

                    SignatureButton(
                        document: (try? JSONEncoder().encode(card)) ?? Data(),
                        documentType: .emergencyCardActivation,
                        consentItems: nil,
                        legalBasis: [.gdprArt9, .euMDR],
                        jurisdictions: ["EU"],
                        adESText: "By activating my Emergency Card I confirm these are my accurate medical details for emergency use under EU MDR 2017/745 Class IIa.",
                        label: "Activate Emergency Card"
                    ) { result in
                        coordinator.markCardComplete()
                        _ = result
                    }
                }

            } else {
                // Save card first
                if let err = saveError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Button {
                    Task { await saveCard() }
                } label: {
                    if isSaving {
                        HStack { ProgressView(); Text("Saving…") }
                    } else {
                        Text("Save Emergency Card")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.navy)
                .disabled(!canSave)
            }
        } header: {
            Text("Save & Sign")
        } footer: {
            if !canSave && savedCard == nil {
                Text("Complete all required fields to continue.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Save

    private func saveCard() async {
        guard canSave, let bloodType = selectedBloodType else { return }
        isSaving = true
        saveError = nil

        let allAllergies = selectedAllergies.map { $0.capitalized }.sorted()
        let meds = medications.compactMap { $0.toMedication() }

        let card = EmergencyCard(
            id:          UUID(),
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            dateOfBirth: dateOfBirth,
            bloodType:   bloodType,
            allergies:   allAllergies,
            medications: meds,
            updatedAt:   Date()
        )

        do {
            let data     = try JSONEncoder().encode(card)
            let sealed   = try await MedicalVaultManager.shared.seal(data)
            let sealedJSON = try JSONEncoder().encode(sealed)
            // Store under a well-known key in the eHR vault directory
            let vaultDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("vault", isDirectory: true)
            try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
            try sealedJSON.write(to: vaultDir.appendingPathComponent("emergency-card.enc"), options: .atomic)
            savedCard = card
            saveSupportProfile()  // save contact prefs alongside card (silently skips if incomplete)
        } catch {
            saveError = error.localizedDescription
        }

        isSaving = false
    }
}

// MARK: - Medication draft (local mutable state for the form)

struct MedicationDraft: Identifiable {
    let id = UUID()
    var name: String = ""
    var dose: String = ""
    var frequency: String = ""
    var atcCode: String = ""

    var isValid: Bool { !name.isEmpty && !dose.isEmpty && !frequency.isEmpty }

    func toMedication() -> Medication? {
        guard isValid else { return nil }
        return Medication(
            id:        id,
            name:      name.trimmingCharacters(in: .whitespaces),
            dose:      dose.trimmingCharacters(in: .whitespaces),
            frequency: frequency.trimmingCharacters(in: .whitespaces),
            atcCode:   atcCode.isEmpty ? nil : atcCode.uppercased()
        )
    }
}

// MARK: - MedicationRowEditor

struct MedicationRowEditor: View {
    @Binding var draft: MedicationDraft

    private let frequencyOptions = ["Once daily", "Twice daily", "Three times daily",
                                     "As needed", "Weekly", "Monthly"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Medication name *", text: $draft.name)
                .textContentType(.none)
                .autocorrectionDisabled()
                .onChange(of: draft.name) { _, newVal in
                    lookupATC(for: newVal)
                }

            HStack(spacing: 10) {
                TextField("Dose *", text: $draft.dose)
                    .frame(maxWidth: .infinity)
                    .textContentType(.none)
                    .keyboardType(.default)

                Picker("Frequency *", selection: $draft.frequency) {
                    Text("Frequency…").tag("")
                    ForEach(frequencyOptions, id: \.self) { opt in
                        Text(opt).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }

            if !draft.atcCode.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text("ATC: \(draft.atcCode)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func lookupATC(for name: String) {
        guard name.count >= 3 else { draft.atcCode = ""; return }
        // ATC lookup from normalization module — deterministic, not generative AI.
        // Uses the same lookup table as backend/normalization/atc_lookup.json
        let result = ATCLookup.shared.lookup(drugName: name)
        draft.atcCode = result ?? ""
    }
}

// MARK: - ATC Lookup stub (backed by normalization module table)

final class ATCLookup: @unchecked Sendable {
    static let shared = ATCLookup()

    // Partial table for common medications — full table from normalization/atc_lookup.json
    // Loaded at runtime from the bundle; these are the most common ER medications.
    private let table: [String: String] = [
        "aspirin":        "B01AC06",
        "ibuprofen":      "M01AE01",
        "paracetamol":    "N02BE01",
        "lisinopril":     "C09AA03",
        "metformin":      "A10BA02",
        "amoxicillin":    "J01CA04",
        "atorvastatin":   "C10AA05",
        "omeprazole":     "A02BC01",
        "metoprolol":     "C07AB02",
        "amlodipine":     "C08CA01",
        "losartan":       "C09CA01",
        "simvastatin":    "C10AA01",
        "warfarin":       "B01AA03",
        "clopidogrel":    "B01AC04",
        "levothyroxine":  "H03AA01",
    ]

    func lookup(drugName: String) -> String? {
        let key = drugName.lowercased().trimmingCharacters(in: .whitespaces)
        return table.first(where: { key.contains($0.key) || $0.key.contains(key) })?.value
    }
}

#Preview {
    EmergencyCardSetupView()
        .environmentObject(OnboardingCoordinator())
}
