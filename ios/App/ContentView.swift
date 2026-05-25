//
//  ContentView.swift
//  nobordershealthcare
//
//  iOS 26 Liquid Glass design language:
//  • Tab bar    — Liquid Glass applied automatically when targeting iOS 26
//                 via the new Tab API (no explicit modifier needed on TabView)
//  • Cards      — .ultraThinMaterial for depth without full glass tint
//  • Navigation — inline title, glass nav bar (system default on iOS 26);
//                 solid toolbarBackground removed so glass renders
//  • Floating   — NetworkStatusChip + MK avatar use .glassEffect(in:)
//  • Emergency  — dark solid navy, NO glass (life-critical readability first)
//

import SwiftUI

// MARK: - Adaptive colors

extension Color {
    /// Brand navy #2E317A
    static let navy = Color(red: 46/255, green: 49/255, blue: 122/255)

    /// Linen (#F5F1EB) in light mode, system background in dark.
    /// Acts as the page canvas beneath .ultraThinMaterial cards.
    static let appBg = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor.systemBackground
            : UIColor(red: 245/255, green: 241/255, blue: 235/255, alpha: 1)
    })

    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >>  8) & 0xFF) / 255,
            blue:  Double( v        & 0xFF) / 255
        )
    }
}

// MARK: - NetworkStatusChip
// Rendered as a Liquid Glass capsule — sits in the trailing toolbar of all
// secondary tabs. Self-refreshes every 30 s via TimelineView.

struct NetworkStatusChip: View {
    @EnvironmentObject var detector: NetworkCountryDetector
    var showSync: Bool = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .trailing, spacing: 2) {
                Text(detector.networkStatus.label)
                    .font(.caption2).fontWeight(.semibold)
                if showSync, let sync = detector.lastSyncDate {
                    Text("Synced \(sync, style: .relative) ago")
                        .font(.system(size: 9)).opacity(0.65)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            // ▸ Liquid Glass pill — iOS 26 GlassEffect
            .glassEffect(in: Capsule())
        }
    }
}

// MARK: - Root ContentView
// Uses the iOS 18+ Tab API (available on our iOS 26 deployment target).
// On iOS 26 the system renders the tab bar as a floating Liquid Glass bar
// automatically — no .glassEffect() call required on TabView itself.

struct ContentView: View {
    @State private var showEmergency = false
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home",      systemImage: "house.fill",                        value: 0) {
                HomeView(showEmergency: $showEmergency)
            }
            Tab("Records",   systemImage: "folder.fill",                       value: 1) {
                RecordsView()
            }
            Tab("Telemed",   systemImage: "video.fill",                        value: 2) {
                TelemedView()
            }
            Tab("Translate", systemImage: "bubble.left.and.bubble.right.fill", value: 3) {
                TranslateView()
            }
            Tab("Profile",   systemImage: "person.fill",                       value: 4) {
                ProfileView()
            }
        }
        .tint(Color.navy)
        .fullScreenCover(isPresented: $showEmergency) {
            EmergencyView(isPresented: $showEmergency)
        }
    }
}

// MARK: - HomeView

struct HomeView: View {
    @Binding var showEmergency: Bool
    @StateObject private var detector = NetworkCountryDetector.shared

    // Activation wizard — shown until all 3 steps are ticked
    @AppStorage("wizardDoctorDone")    private var wizardDoctorDone: Bool = false
    @AppStorage("wizardGuardianDone")  private var wizardGuardianDone: Bool = false
    @AppStorage("wizardInsuranceDone") private var wizardInsuranceDone: Bool = false

    private var wizardAllDone: Bool { wizardDoctorDone && wizardGuardianDone && wizardInsuranceDone }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    emergencyCard
                    if !wizardAllDone { activationWizardCard }
                    quickActions
                    vitalsSection
                    documentsSection
                }
                .padding(.bottom, 24)
            }
            .background(Color.appBg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // ── Left: brand name + live network status ─────────────────
                ToolbarItem(placement: .navigationBarLeading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("#nobordershealthcare")
                            .font(.subheadline).fontWeight(.bold)
                            .foregroundStyle(Color.navy)
                        Text(detector.networkStatus.label)
                            .font(.caption2).foregroundStyle(.secondary)
                        if let sync = detector.lastSyncDate {
                            Text("Synced \(sync, style: .relative) ago")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                // ── Right: MK avatar — Liquid Glass circle ─────────────────
                ToolbarItem(placement: .navigationBarTrailing) {
                    ZStack {
                        Text("MK").font(.footnote).fontWeight(.bold)
                    }
                    .frame(width: 34, height: 34)
                    // ▸ Liquid Glass avatar — iOS 26 GlassEffect
                    .glassEffect(in: Circle())
                }
            }
            // iOS 26: navigation bar renders as Liquid Glass by default.
            // The solid .toolbarBackground is intentionally absent so the
            // system glass blur appears behind the inline title + toolbar items.
        }
    }

    // ── Activation wizard — .ultraThinMaterial card, visible until all 3 done ──

    private var activationWizardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Complete Your Setup")
                        .font(.headline)
                    Text("\(wizardStepsDone)/3 steps completed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Mini progress ring
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(wizardStepsDone) / 3.0)
                        .stroke(Color.navy, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring, value: wizardStepsDone)
                }
                .frame(width: 32, height: 32)
            }

            Divider()

            wizardRow(
                done: $wizardDoctorDone,
                icon: "stethoscope",
                title: "Family Doctor",
                subtitle: "First visit questionnaire + GP assignment"
            )
            Divider().padding(.leading, 44)
            wizardRow(
                done: $wizardGuardianDone,
                icon: "person.2.fill",
                title: "Personal Data & Guardian",
                subtitle: "Upload ID documents + designate proxy"
            )
            Divider().padding(.leading, 44)
            wizardRow(
                done: $wizardInsuranceDone,
                icon: "creditcard.fill",
                title: "Insurance",
                subtitle: "Verify health & travel policies"
            )
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.navy.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var wizardStepsDone: Int {
        [wizardDoctorDone, wizardGuardianDone, wizardInsuranceDone].filter { $0 }.count
    }

    private func wizardRow(done: Binding<Bool>, icon: String, title: String, subtitle: String) -> some View {
        Button {
            withAnimation(.spring(duration: 0.25)) { done.wrappedValue = true }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(done.wrappedValue ? Color.navy : Color.secondary.opacity(0.12))
                        .frame(width: 32, height: 32)
                    if done.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.caption).fontWeight(.bold).foregroundStyle(.white)
                    } else {
                        Image(systemName: icon)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline).fontWeight(.semibold)
                        .strikethrough(done.wrappedValue, color: .secondary)
                        .foregroundStyle(done.wrappedValue ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                if !done.wrappedValue {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // ── Emergency card — dark solid gradient, NO glass (readability first) ──

    private var emergencyCard: some View {
        Button { showEmergency = true } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color(hex: "12153F"), Color(hex: "2E317A")],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, minHeight: 188)

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("EMERGENCY ACCESS")
                            .font(.caption2).fontWeight(.bold)
                            .foregroundStyle(.white.opacity(0.6)).tracking(1.5)
                        Spacer()
                        Text("A+").font(.title2).fontWeight(.heavy).foregroundStyle(.red)
                    }
                    Text("Maria K.")
                        .font(.title2).fontWeight(.bold).foregroundStyle(.white)
                    HStack(spacing: 6) {
                        allergyPill("⚠️ Penicillin")
                        allergyPill("⚠️ Ibuprofen")
                    }
                    Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                    Text("Type 1 Diabetes · Metformin 500mg")
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode").foregroundStyle(.white.opacity(0.5))
                        Text("Tap to share QR").font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(16)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func allergyPill(_ label: String) -> some View {
        Text(label)
            .font(.caption2).fontWeight(.semibold).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.red.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // ── Quick actions 2×2 — .ultraThinMaterial cards ──────────────────────

    private var quickActions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                actionBtn("doc.text.fill",   "Health Records", Color.navy)
                actionBtn("video.fill",       "See a Doctor",  .blue)
            }
            HStack(spacing: 10) {
                actionBtn("bubble.left.and.bubble.right.fill", "Translate",  Color(hex: "4A90D9"))
                actionBtn("cross.circle.fill",                  "Emergency", .red) { showEmergency = true }
            }
        }
        .padding(.horizontal, 16)
    }

    private func actionBtn(
        _ icon: String, _ title: String, _ tint: Color,
        action: (() -> Void)? = nil
    ) -> some View {
        Button { action?() } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 28)
                Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            // ▸ .ultraThinMaterial card
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).frame(maxWidth: .infinity)
    }

    // ── Recent vitals — .ultraThinMaterial cards ──────────────────────────

    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Recent Vitals")
            HStack(spacing: 10) {
                vitalCard("heart.fill",        "118/78", "mmHg", "Blood Pressure", .red)
                vitalCard("waveform.path.ecg", "72",     "bpm",  "Heart Rate",     .orange)
                vitalCard("drop.fill",         "7.4",    "%",    "HbA1c",          .blue)
            }
            .padding(.horizontal, 16)
        }
    }

    private func vitalCard(
        _ icon: String, _ value: String, _ unit: String,
        _ label: String, _ tint: Color
    ) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            Text(value).font(.title3).fontWeight(.bold)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(12)
        // ▸ .ultraThinMaterial card
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // ── Documents — .ultraThinMaterial card ──────────────────────────────

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Documents")
            VStack(spacing: 0) {
                docRow("doc.fill",        "Hospital da Luz Report", "Apr 2026", .blue)
                Divider().padding(.leading, 52)
                docRow("pills.fill",      "Metformin Prescription",  "Mar 2026", .green)
                Divider().padding(.leading, 52)
                docRow("creditcard.fill", "AOK Insurance Card",      "Jan 2026", .purple)
            }
            // ▸ .ultraThinMaterial card
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    private func docRow(_ icon: String, _ title: String, _ date: String, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).padding(.horizontal, 16)
    }
}

// MARK: - RecordsView
// Delegates to DocumentView which owns the full DocumentVault UI.
// The NavigationStack and toolbar (including NetworkStatusChip) live inside
// DocumentView so the scan/import toolbar items share the same nav bar.

struct RecordsView: View {
    @EnvironmentObject var detector: NetworkCountryDetector

    var body: some View {
        DocumentView()
    }
}

// MARK: - TelemedView

struct TelemedView: View {
    @EnvironmentObject var detector: NetworkCountryDetector

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                // ▸ .ultraThinMaterial content card
                VStack(spacing: 20) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(Color.navy)
                    VStack(spacing: 8) {
                        Text("Telemedicine").font(.title2).fontWeight(.bold)
                        Text("Connect with a doctor\nanytime, anywhere.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button("Start Consultation") {}
                        .buttonStyle(.borderedProminent).tint(Color.navy)
                }
                .padding(32)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBg.ignoresSafeArea())
            .navigationTitle("Telemed")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { NetworkStatusChip() }
            }
        }
    }
}

// MARK: - TranslateView

struct TranslateView: View {
    @EnvironmentObject var detector: NetworkCountryDetector
    @State private var inputText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // ▸ .ultraThinMaterial text editor card
                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("Enter text to translate…")
                            .foregroundStyle(.secondary).padding(16)
                    }
                    TextEditor(text: $inputText)
                        .frame(height: 140)
                        .opacity(inputText.isEmpty ? 0.25 : 1)
                        .padding(8)
                        .scrollContentBackground(.hidden)   // makes TextEditor bg transparent
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))

                Button("Translate to English") {}
                    .buttonStyle(.borderedProminent)
                    .tint(Color.navy)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            .padding()
            .background(Color.appBg.ignoresSafeArea())
            .navigationTitle("Translate")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { NetworkStatusChip() }
            }
        }
    }
}

// MARK: - ProfileView

struct ProfileView: View {
    @AppStorage("colorScheme") var schemePref: String = "auto"
    @EnvironmentObject var detector: NetworkCountryDetector

    // ── Support & Contact state ───────────────────────────────────────────────
    @State private var supportProfile: SupportProfile? = nil
    @State private var showSupportEdit: Bool = false

    var schemeLabel: String {
        switch schemePref {
        case "light": return "☀️ Day"
        case "dark":  return "🌙 Night"
        default:      return "⚙️ Auto"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Avatar ────────────────────────────────────────────────
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(Color.navy).frame(width: 56, height: 56)
                            Text("MK").font(.title2).fontWeight(.bold).foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Maria Kowalczyk").font(.headline)
                            Text("DOB: 12.08.1985 · Polish")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // ── Appearance ────────────────────────────────────────────
                Section("Appearance") {
                    HStack {
                        Text("Color Mode")
                        Spacer()
                        Text(schemeLabel).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        schemeBtn("☀️ Day",   "light")
                        schemeBtn("⚙️ Auto",  "auto")
                        schemeBtn("🌙 Night", "dark")
                    }
                    .padding(.vertical, 2)
                }

                // ── Network ───────────────────────────────────────────────
                Section("Network") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(detector.networkStatus.label)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Last Sync")
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            if let sync = detector.lastSyncDate {
                                Text("Synced \(sync, style: .relative) ago")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Not yet synced")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // ── Support & Contact ──────────────────────────────────────
                supportContactSection

                // ── Account ───────────────────────────────────────────────
                Section("Account") {
                    Label("Health Profile", systemImage: "person.fill")
                    Label("Insurance",      systemImage: "creditcard.fill")
                    Label("Language",       systemImage: "globe")
                    Label("Sign Out",       systemImage: "arrow.right.circle")
                        .foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBg.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { NetworkStatusChip() }
            }
            .onAppear { loadSupportProfile() }
            .sheet(isPresented: $showSupportEdit) {
                SupportProfileEditView(
                    profile: supportProfile,
                    onSaved: { updated in
                        supportProfile = updated
                    }
                )
            }
        }
    }

    // ── Support section ────────────────────────────────────────────────────────

    @ViewBuilder
    private var supportContactSection: some View {
        Section {
            HStack {
                Text("How to address you")
                Spacer()
                Text(supportProfile.flatMap { $0.salutation.isEmpty ? nil : $0.salutation } ?? "Not set")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Support nickname")
                Spacer()
                Text(supportProfile.flatMap { $0.nickname.isEmpty ? nil : $0.nickname } ?? "Not set")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Security question")
                Spacer()
                Image(systemName: supportProfile.map { !$0.securityAnswerHash.isEmpty } == true
                      ? "checkmark.shield.fill" : "shield")
                    .foregroundStyle(supportProfile.map { !$0.securityAnswerHash.isEmpty } == true
                                     ? Color.green : Color.secondary)
            }
            Button("Edit Support Profile") {
                showSupportEdit = true
            }
            .foregroundStyle(Color.navy)
        } header: {
            Text("Support & Contact")
        } footer: {
            Text("Our support team will NEVER ask for your medical data — only nickname + DOB + security answer.")
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    private func loadSupportProfile() {
        supportProfile = SupportProfileStore.load()
    }

    private func schemeBtn(_ label: String, _ value: String) -> some View {
        Button { schemePref = value } label: {
            Text(label)
                .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(schemePref == value ? Color.navy : Color.secondary.opacity(0.15))
                .foregroundStyle(schemePref == value ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - EmergencyView (always dark navy — readability first, no glass)

struct EmergencyView: View {
    @Binding var isPresented: Bool
    @StateObject private var detector = NetworkCountryDetector.shared
    @State private var pulse = false
    @State private var showLanguagePicker = false
    @State private var showForensicQR = false
    @State private var forensicUnlocked = false

    // Profile-aware rendering — read from Keychain at view appear.
    @State private var profileType: ProfileType = .civilian
    @State private var opRole: OperationalRole = .none
    @State private var protection: IdentityProtectionLevel = .standard
    // isTranslating is reserved for future async translation paths.
    // All pilot-language strings use the static lookup table below — instant, no async.
    @State private var isTranslating = false
    // Screenshot / screen-recording protection — iOS 17+ EnvironmentValue.
    // When the system reports the scene is being captured (screen record, AirPlay,
    // mirror, or screenshot via assistive tech), we overlay an opaque blur so
    // the patient's emergency card and QR code are not captured.
    @Environment(\.isSceneCaptured) private var isSceneCaptured

    // Complete static translation table: UI labels + known medical display terms.
    // Keys are canonical English strings. No opus-mt round-trip needed for these.
    // Add new terms here when the patient card gains more fields.
    private static let staticUI: [String: [String: String]] = [
        "ALLERGIES":   ["uk": "АЛЕРГІЇ",   "de": "ALLERGIEN",   "pt": "ALERGIAS",   "ru": "АЛЛЕРГИИ"],
        "MEDICATIONS": ["uk": "ЛІКИ",      "de": "MEDIKAMENTE", "pt": "MEDICAMENTOS","ru": "ЛЕКАРСТВА"],
        "EMERGENCY ACCESS": [
            "uk": "ЕКСТРЕНА ДОПОМОГА", "de": "NOTFALLZUGANG",
            "pt": "ACESSO DE EMERGÊNCIA", "ru": "ЭКСТРЕННЫЙ ДОСТУП",
        ],
        "Scan to access full medical record": [
            "uk": "Скануйте для доступу до медичної картки",
            "de": "Scannen für Zugang zur Patientenakte",
            "pt": "Digitalize para aceder ao registo médico",
            "ru": "Сканируйте для доступа к медкарте",
        ],
        "Works offline · Local JWT": [
            "uk": "Працює офлайн · Локальний JWT",
            "de": "Funktioniert offline · Lokales JWT",
            "pt": "Funciona offline · JWT local",
            "ru": "Работает офлайн · Локальный JWT",
        ],
        "Set manually": [
            "uk": "Встановити вручну", "de": "Manuell einstellen",
            "pt": "Definir manualmente", "ru": "Установить вручную",
        ],
        "Polish": ["uk": "Польська", "de": "Polnisch", "pt": "Polaco", "ru": "Польский"],
        // Medical display labels — fixed pilot terms; no opus-mt needed
        "Penicillin": ["uk": "Пеніцилін",      "de": "Penicillin",  "pt": "Penicilina",   "ru": "Пенициллин"],
        "Ibuprofen":  ["uk": "Ібупрофен",      "de": "Ibuprofen",   "pt": "Ibuprofeno",   "ru": "Ибупрофен"],
        "Sulfa":      ["uk": "Сульфаніламіди", "de": "Sulfonamide", "pt": "Sulfonamidas", "ru": "Сульфаниламиды"],
        "Metformin":  ["uk": "Метформін",      "de": "Metformin",   "pt": "Metformina",   "ru": "Метформин"],
        "Lisinopril": ["uk": "Лізиноприл",     "de": "Lisinopril",  "pt": "Lisinopril",   "ru": "Лизиноприл"],
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                    // ── Top bar: close (left) + language flag (right) ──────
                    HStack {
                        Button { isPresented = false } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Button { showLanguagePicker = true } label: {
                            HStack(spacing: 4) {
                                Text(detector.current.flag)
                                Text(detector.current.isoCode)
                                    .font(.caption.bold()).foregroundColor(.white)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.2))
                            .cornerRadius(8)
                        }
                    }
                    .padding(.top, 12)

                    // ── Pulsing red dot ────────────────────────────────────
                    VStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Color.red.opacity(0.25))
                                .frame(width: pulse ? 72 : 50, height: pulse ? 72 : 50)
                                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                            Circle().fill(Color.red).frame(width: 20, height: 20)
                        }
                        Text(t("EMERGENCY ACCESS", lang: currentLang))
                            .font(.title2).fontWeight(.heavy)
                            .foregroundStyle(.white).tracking(2)
                    }
                    .onAppear { pulse = true }

                    // ── Patient card — profile-aware rendering ─────────────
                    profileAwareCard

                    // ── Forensic QR button (military/firstResponder only) ───
                    if profileType == .military || profileType == .firstResponder {
                        Button {
                            Task { await requestForensicUnlock() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "dna").foregroundStyle(.green)
                                Text("Forensic ID").fontWeight(.semibold)
                                Spacer()
                                Text("5 min TTL").font(.caption2).foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(14)
                            .background(Color.green.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
                        .overlay {
                            if showForensicQR {
                                forensicQROverlay
                            }
                        }
                    }

                    // ── Detection source label ─────────────────────────────
                    Text(translatedSourceLabel())
                        .font(.caption2).foregroundColor(.white.opacity(0.5))

                    // ── QR placeholder (offline — local JWT) ───────────────
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 160, height: 160)
                            .overlay(
                                Image(systemName: "qrcode")
                                    .font(.system(size: 80)).foregroundStyle(.white.opacity(0.4))
                            )
                        Text(t("Scan to access full medical record", lang: currentLang))
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                        Text(t("Works offline · Local JWT", lang: currentLang))
                            .font(.caption2).foregroundStyle(.white.opacity(0.3))
                    }

                    // ── Voice interpreter button ───────────────────────────
                    Button {} label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mic.fill")
                            Text("Start AI Voice Interpreter").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity).padding(16)
                        .background(Color.red).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Color(hex: "12153F"))
        .ignoresSafeArea()
        .confirmationDialog("Emergency Card Language", isPresented: $showLanguagePicker) {
            Button("🇺🇦 Ukrainian")  { detector.setManual(isoCode: "UA", language: "uk") }
            Button("🇩🇪 German")     { detector.setManual(isoCode: "DE", language: "de") }
            Button("🇵🇹 Portuguese") { detector.setManual(isoCode: "PT", language: "pt") }
            Button("🇷🇺 Russian")    { detector.setManual(isoCode: "RU", language: "ru") }
            Button("🇬🇧 English")    { detector.setManual(isoCode: "GB", language: "en") }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            await detector.detect()
        }
        .onAppear {
            profileType = ProfileTypeStore.shared.read()
            let op = OperationalProfileStore.shared.read()
            opRole = op?.operationalRole ?? .none
            protection = op?.identityProtection ?? .standard
        }
        // Scope dark mode to this view tree ONLY.
        // .environment(\.colorScheme, .dark) changes the SwiftUI environment
        // without touching UIWindow.overrideUserInterfaceStyle — the rest of
        // the app is unaffected when this fullScreenCover is dismissed.
        .environment(\.colorScheme, .dark)
        // ── Screenshot / screen-recording protection ────────────────────────
        // isSceneCaptured (iOS 17+) is true during screen recording, AirPlay
        // mirroring, and captured screenshots via assistive technology.
        // We overlay an opaque blur so the QR code and medical data are not
        // captured.  The overlay is removed the instant capture stops so the
        // emergency card is visible in-person at all other times.
        .overlay {
            if isSceneCaptured {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "eye.slash.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Screen capture is disabled\non this screen")
                            .multilineTextAlignment(.center)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // ── Profile-aware card ─────────────────────────────────────────────────

    @ViewBuilder
    private var profileAwareCard: some View {
        switch protection {
        case .covert:
            covertCard
        case .minimal:
            minimalCard
        case .reduced:
            reducedCard
        case .standard:
            standardCard
        }
    }

    // .covert — special ops: blood type + allergies ONLY, no identity
    private var covertCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("⚕ EMERGENCY MEDICAL")
                    .font(.caption).fontWeight(.bold).foregroundStyle(.white.opacity(0.6)).tracking(1.5)
                Spacer()
                Text("A+").font(.title).fontWeight(.heavy).foregroundStyle(.red)
            }
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            allergySection
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            medSection
            // NO identity, NO NOK — covert profile
        }
        .cardStyle()
    }

    // .minimal — police/NGU: medical + NOK via duty, no affiliation
    private var minimalCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("🪖⚖ MEDICAL CARD")
                        .font(.caption).fontWeight(.bold).foregroundStyle(.white.opacity(0.6)).tracking(1.5)
                    Text("Authority: Law Enforcement")   // no country, no unit
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text("A+").font(.title).fontWeight(.heavy).foregroundStyle(.red)
            }
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            allergySection
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            medSection
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            Text("NOK: via duty officer")
                .font(.caption).foregroundStyle(.white.opacity(0.55))
        }
        .cardStyle()
    }

    // .reduced — military: service number + medical + DNA ref + NOK via duty
    private var reducedCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("🪖 COMBAT MEDICAL CARD")
                        .font(.caption).fontWeight(.bold).foregroundStyle(.white.opacity(0.6)).tracking(1.5)
                    Text("Service №: ••••••  (biometric required)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    Text("Nationality: UA")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("A+").font(.title2).fontWeight(.heavy).foregroundStyle(.red)
                    Text("✓ VERIFIED").font(.system(size: 9)).foregroundStyle(.green)
                }
            }
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            allergySection
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            medSection
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOK: via duty officer")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                    Text("DNA Ref: on file")
                        .font(.caption2).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .cardStyle()
    }

    // .standard — civilian: full name, DOB, full data
    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Maria Kowalczyk")
                        .font(.title3).fontWeight(.bold).foregroundStyle(.white)
                    Text("DOB: \(formattedDOB()) · " + t("Polish", lang: currentLang))
                        .font(.subheadline).foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Text("A+").font(.title).fontWeight(.heavy).foregroundStyle(.red)
            }
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            allergySection
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            medSection
        }
        .cardStyle()
    }

    // .sarTeam / civilDefense — EUCP ID shown
    private var sarCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("🦺 RESCUE TEAM MEMBER")
                        .font(.caption).fontWeight(.bold).foregroundStyle(.white.opacity(0.6)).tracking(1.5)
                    Text("EUCP ID: UCPM-DE-2024-001234")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    Text("Maria Kowalczyk").font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Text("A+").font(.title2).fontWeight(.heavy).foregroundStyle(.red)
            }
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            allergySection
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            medSection
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            Text("NOK: direct contact")
                .font(.caption).foregroundStyle(.white.opacity(0.55))
        }
        .cardStyle()
    }

    private var allergySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("ALLERGIES", lang: currentLang))
                .font(.caption2).fontWeight(.bold)
                .foregroundStyle(Color.red).tracking(1.5)
            HStack(spacing: 8) {
                allergyBadge(t("Penicillin", lang: currentLang))
                allergyBadge(t("Ibuprofen", lang: currentLang))
                allergyBadge(t("Sulfa", lang: currentLang))
            }
        }
    }

    private var medSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("MEDICATIONS", lang: currentLang))
                .font(.caption2).fontWeight(.bold)
                .foregroundStyle(.white.opacity(0.5)).tracking(1.5)
            medRow(t("Metformin", lang: currentLang),  "500mg", "2×/day")
            medRow(t("Lisinopril", lang: currentLang), "10mg",  "1×/day")
        }
    }

    // ── Forensic QR overlay — DVI use only, 5 min TTL ─────────────────────

    private var forensicQROverlay: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("⚠️ FOR AUTHORIZED DVI USE ONLY")
                    .font(.caption).fontWeight(.bold).foregroundStyle(.orange).tracking(1)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 180, height: 180)
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.system(size: 90)).foregroundStyle(.white.opacity(0.4))
                    )
                VStack(spacing: 4) {
                    Text("Scope: DNA ref · Identifying marks · Dental ref · Blood type")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                    Text("TTL: 5 minutes · Biometric required each display")
                        .font(.caption2).foregroundStyle(.orange.opacity(0.7))
                }
                Button("Close") { showForensicQR = false; forensicUnlocked = false }
                    .foregroundStyle(.white).padding(.horizontal, 32)
            }
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func requestForensicUnlock() async {
        do {
            try await BiometricAuth.shared.evaluate(
                reason: "Authenticate to display Forensic ID — authorized DVI personnel only"
            )
            forensicUnlocked = true
            showForensicQR = true
            // Auto-dismiss after 300 seconds (5 min TTL)
            try await Task.sleep(nanoseconds: 300_000_000_000)
            showForensicQR = false
            forensicUnlocked = false
        } catch {
            forensicUnlocked = false
        }
    }

    // ── Translation helpers ────────────────────────────────────────────────

    // Current display language — driven by detector; view re-renders on change.
    private var currentLang: String { detector.current.language }

    // Instant static lookup. Returns English key when lang == "en" or key is missing.
    // View re-renders automatically when detector publishes a language change.
    private func t(_ key: String, lang: String) -> String {
        guard lang != "en" else { return key }
        return Self.staticUI[key]?[lang] ?? key
    }

    // DOB display format adapted to locale (demo value: 12 Aug 1985).
    // DE/UA/RU: dd.MM.yyyy  |  PT: dd/MM/yyyy  |  EN: MM/dd/yyyy
    private func formattedDOB() -> String {
        switch currentLang {
        case "de", "uk", "ru": return "12.08.1985"
        case "pt":             return "12/08/1985"
        default:               return "08/12/1985"
        }
    }

    // Translates just the "Set manually" text part of the detection source label,
    // preserving the leading emoji from DetectedCountry.sourceLabel.
    private func translatedSourceLabel() -> String {
        let label = detector.current.sourceLabel
        let lang  = currentLang
        guard lang != "en", label.hasPrefix("✋ ") else { return label }
        let translated = Self.staticUI["Set manually"]?[lang] ?? String(label.dropFirst(3))
        return "✋ " + translated
    }

    private func allergyBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption).fontWeight(.semibold).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.red.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func medRow(_ name: String, _ dose: String, _ freq: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline).fontWeight(.semibold).foregroundStyle(.white)
                Text(dose).font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Text(freq).font(.caption).foregroundStyle(.white.opacity(0.45))
        }
    }
}

// MARK: - ChangeSecurityQuestionSheet
//
// Two-phase sheet:
//   Phase 1 — verify current answer (hash-compared; plaintext never sent anywhere)
//   Phase 2 — pick new question + enter new answer (hash on save, zero immediately)

struct ChangeSecurityQuestionSheet: View {
    let profile: SupportProfile
    @Binding var isPresented: Bool
    let onSaved: (SupportProfile) -> Void

    @State private var phase: Int = 1

    // Phase 1
    @State private var currentAnswerInput: String = ""
    @State private var verifyError: String? = nil

    // Phase 2
    @State private var newQuestion: SecurityQuestion = .firstPet
    @State private var customNewQuestion: String = ""
    @State private var newAnswer: String = ""
    @State private var newAnswerConfirm: String = ""
    @State private var saveError: String? = nil

    var body: some View {
        NavigationStack {
            if phase == 1 { verifyPhase } else { setNewPhase }
        }
    }

    // ── Phase 1: verify current answer ────────────────────────────────────────

    private var verifyPhase: some View {
        Form {
            Section {
                Text(profile.securityQuestion)
                    .font(.subheadline).foregroundStyle(.secondary)
                SecureField("Current answer", text: $currentAnswerInput)
                if let err = verifyError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Verify current security question")
            } footer: {
                Text("Enter your current answer to proceed.")
            }
        }
        .navigationTitle("Change Security Question")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isPresented = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Verify") { verifyCurrentAnswer() }
                    .disabled(currentAnswerInput.isEmpty)
            }
        }
    }

    // ── Phase 2: set new question + answer ────────────────────────────────────

    private var setNewPhase: some View {
        Form {
            Section {
                Picker("New question", selection: $newQuestion) {
                    ForEach(SecurityQuestion.allCases, id: \.self) { q in
                        Text(q.displayLabel).tag(q)
                    }
                }
                .pickerStyle(.menu)

                if newQuestion == .customQuestion {
                    TextField("Your custom question", text: $customNewQuestion)
                        .autocorrectionDisabled()
                }

                SecureField("New answer",         text: $newAnswer)
                SecureField("Confirm new answer", text: $newAnswerConfirm)

                if !newAnswer.isEmpty, !newAnswerConfirm.isEmpty, newAnswer != newAnswerConfirm {
                    Text("Answers do not match").font(.caption).foregroundStyle(.orange)
                }
                if let err = saveError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("New security question")
            } footer: {
                Text("Your answer is hashed immediately and never stored in plaintext.")
            }
        }
        .navigationTitle("New Security Question")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isPresented = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveNewQuestion() }
                    .disabled(!canSaveNew)
            }
        }
    }

    // ── Logic ──────────────────────────────────────────────────────────────────

    private var canSaveNew: Bool {
        !newAnswer.isEmpty
        && newAnswer == newAnswerConfirm
        && (newQuestion != .customQuestion || !customNewQuestion.isEmpty)
    }

    private func verifyCurrentAnswer() {
        if profile.verifyAnswer(currentAnswerInput) {
            verifyError       = nil
            currentAnswerInput = ""   // zero plaintext from memory
            phase = 2
        } else {
            verifyError = "Incorrect answer. Please try again."
        }
    }

    private func saveNewQuestion() {
        guard canSaveNew else { return }

        let questionText: String
        let questionKey: String
        if newQuestion == .customQuestion {
            questionText = customNewQuestion.trimmingCharacters(in: .whitespaces)
            questionKey  = SecurityQuestion.customQuestion.rawValue
        } else {
            questionText = newQuestion.displayLabel
            questionKey  = newQuestion.rawValue
        }

        var updated = profile
        updated.securityQuestion    = questionText
        updated.securityQuestionKey = questionKey

        do {
            try updated.setAnswer(newAnswer)
        } catch {
            saveError = error.localizedDescription
            return
        }

        // Zero plaintext from @State
        newAnswer        = ""
        newAnswerConfirm = ""

        SupportProfileStore.save(updated)
        onSaved(updated)
        isPresented = false
    }
}

// MARK: - SupportProfileEditView
//
// Sheet for editing salutation, nickname, and changing the security question.
// Loaded from ProfileView via "Edit Support Profile" button.

struct SupportProfileEditView: View {
    let profile: SupportProfile?
    let onSaved: (SupportProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var salutation: String
    @State private var nickname: String
    @State private var showChangeSQ: Bool = false

    init(profile: SupportProfile?, onSaved: @escaping (SupportProfile) -> Void) {
        self.profile  = profile
        self.onSaved  = onSaved
        _salutation   = State(initialValue: profile?.salutation ?? "")
        _nickname     = State(initialValue: profile?.nickname   ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("E.g. Maria, Mr. Smith, Dr. Kovalenko", text: $salutation)
                            .autocorrectionDisabled()
                        Text("How support addresses you in chat")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Support nickname", text: $nickname)
                            .autocorrectionDisabled()
                        Text("Not your medical name — just for support contact")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Contact preferences")
                }

                Section {
                    if let p = profile, !p.securityAnswerHash.isEmpty {
                        HStack {
                            Text("Security question")
                            Spacer()
                            Text(p.securityQuestion.isEmpty ? "Set" : p.securityQuestion)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Button("Change security question") { showChangeSQ = true }
                    } else {
                        Text("No security question set yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Support will NEVER ask for your medical data. Only nickname, DOB, and security answer.")
                }
            }
            .navigationTitle("Edit Support Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .sheet(isPresented: $showChangeSQ) {
                if let p = profile {
                    ChangeSecurityQuestionSheet(
                        profile: p,
                        isPresented: $showChangeSQ
                    ) { updated in
                        onSaved(updated)
                    }
                }
            }
        }
    }

    private func save() {
        var updated = profile ?? SupportProfile(
            salutation:          "",
            nickname:            "",
            securityQuestion:    "",
            securityQuestionKey: nil,
            securityAnswerHash:  "",
            updatedAt:           Date()
        )
        updated.salutation = salutation.trimmingCharacters(in: .whitespaces)
        updated.nickname   = nickname.trimmingCharacters(in: .whitespaces)
        updated.updatedAt  = Date()
        SupportProfileStore.save(updated)
        onSaved(updated)
        dismiss()
    }
}

// MARK: - Card style modifier (emergency views)

private extension View {
    func cardStyle() -> some View {
        self
            .padding(20)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12)))
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(NetworkCountryDetector.shared)
}
