//
//  ContentView.swift
//  nobordershealthcare-app
//

import SwiftUI

// MARK: - Adaptive colors

extension Color {
    /// Brand navy #2E317A
    static let navy = Color(red: 46/255, green: 49/255, blue: 122/255)

    /// Linen (#F5F1EB) in light mode, system dark background in dark mode
    static let appBg = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor.systemBackground
            : UIColor(red: 245/255, green: 241/255, blue: 235/255, alpha: 1)
    })

    /// White in light mode, secondary system bg in dark mode
    static let cardBg = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark ? UIColor.secondarySystemBackground : .white
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
// Self-refreshing every 30 s via TimelineView. Used by the 4 secondary tabs.
// Reads from NetworkCountryDetector (injected as @EnvironmentObject at App level).

struct NetworkStatusChip: View {
    @EnvironmentObject var detector: NetworkCountryDetector
    var showSync: Bool = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .trailing, spacing: 2) {
                // .label already contains the emoji: "🟢 Online" etc.
                Text(detector.networkStatus.label)
                    .font(.caption2).fontWeight(.semibold)
                if showSync, let sync = detector.lastSyncDate {
                    Text("Synced \(sync, style: .relative) ago")
                        .font(.system(size: 9)).opacity(0.65)
                }
            }
        }
    }
}

// MARK: - Root ContentView

struct ContentView: View {
    @State private var showEmergency = false

    var body: some View {
        TabView {
            HomeView(showEmergency: $showEmergency)
                .tabItem { Label("Home",      systemImage: "house.fill") }

            RecordsView()
                .tabItem { Label("Records",   systemImage: "folder.fill") }

            TelemedView()
                .tabItem { Label("Telemed",   systemImage: "video.fill") }

            TranslateView()
                .tabItem { Label("Translate", systemImage: "bubble.left.and.bubble.right.fill") }

            ProfileView()
                .tabItem { Label("Profile",   systemImage: "person.fill") }
        }
        .tint(Color(red: 0.18, green: 0.19, blue: 0.48))
        .fullScreenCover(isPresented: $showEmergency) {
            EmergencyView(isPresented: $showEmergency)
        }
    }
}

// MARK: - HomeView

struct HomeView: View {
    @Binding var showEmergency: Bool
    // NetworkCountryDetector is the single source for network status + country.
    // @StateObject keeps the singleton alive for the lifetime of this tab.
    @StateObject private var detector = NetworkCountryDetector.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    emergencyCard
                    quickActions
                    vitalsSection
                    documentsSection
                }
                .padding(.bottom, 24)
            }
            .background(Color.appBg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // ── Left: brand name + live network status from detector ──
                ToolbarItem(placement: .navigationBarLeading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("#nobordershealthcare")
                            .font(.subheadline).fontWeight(.bold)
                        Text(detector.networkStatus.label)
                            .font(.caption2)
                        if let sync = detector.lastSyncDate {
                            Text("Synced \(sync, style: .relative) ago")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                // ── Right: MK avatar ──────────────────────────────────────
                ToolbarItem(placement: .navigationBarTrailing) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.22)).frame(width: 34, height: 34)
                        Text("MK").font(.footnote).fontWeight(.bold)
                    }
                }
            }
            .toolbarBackground(Color(red: 0.18, green: 0.19, blue: 0.48), for: .navigationBar)
            .toolbarBackground(.visible,   for: .navigationBar)
            .toolbarColorScheme(.dark,     for: .navigationBar)
        }
    }

    // ── Emergency card ────────────────────────────────────────────────────

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

    // ── Quick actions 2×2 ─────────────────────────────────────────────────

    private var quickActions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                actionBtn("doc.text.fill",   "Health Records", Color(red: 0.18, green: 0.19, blue: 0.48))
                actionBtn("video.fill",       "See a Doctor",  .blue)
            }
            HStack(spacing: 10) {
                actionBtn("bubble.left.and.bubble.right.fill", "Translate",  Color(hex: "4A90D9"))
                actionBtn("cross.circle.fill",                  "Emergency", .red) { showEmergency = true }
            }
        }
        .padding(.horizontal, 16)
    }

    private func actionBtn(_ icon: String, _ title: String, _ tint: Color, action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 28)
                Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).frame(maxWidth: .infinity)
    }

    // ── Recent vitals ─────────────────────────────────────────────────────

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

    private func vitalCard(_ icon: String, _ value: String, _ unit: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            Text(value).font(.title3).fontWeight(.bold)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(12)
        .background(Color.cardBg).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // ── Documents ─────────────────────────────────────────────────────────

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Documents")
            VStack(spacing: 0) {
                docRow("doc.fill",        "Hospital da Luz Report", "Apr 2026", .blue)
                Divider().padding(.leading, 52)
                docRow("pills.fill",     "Metformin Prescription",  "Mar 2026", .green)
                Divider().padding(.leading, 52)
                docRow("creditcard.fill", "AOK Insurance Card",      "Jan 2026", .purple)
            }
            .background(Color.cardBg).clipShape(RoundedRectangle(cornerRadius: 12))
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

struct RecordsView: View {
    @EnvironmentObject var detector: NetworkCountryDetector

    var body: some View {
        NavigationStack {
            List {
                Section("Recent") {
                    Label("Hospital da Luz Report", systemImage: "doc.fill")
                    Label("Blood Test Results",     systemImage: "drop.fill")
                    Label("ECG Report",             systemImage: "waveform.path.ecg")
                }
                Section("Prescriptions") {
                    Label("Metformin 500mg",  systemImage: "pills.fill")
                    Label("Lisinopril 10mg",  systemImage: "pills.fill")
                }
                Section("Insurance") {
                    Label("AOK Insurance Card", systemImage: "creditcard.fill")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBg.ignoresSafeArea())
            .navigationTitle("Records")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { NetworkStatusChip() }
            }
        }
    }
}

// MARK: - TelemedView

struct TelemedView: View {
    @EnvironmentObject var detector: NetworkCountryDetector

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "video.fill").font(.system(size: 60)).foregroundStyle(Color(red: 0.18, green: 0.19, blue: 0.48))
                VStack(spacing: 8) {
                    Text("Telemedicine").font(.title2).fontWeight(.bold)
                    Text("Connect with a doctor\nanytime, anywhere.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button("Start Consultation") {}
                    .buttonStyle(.borderedProminent).tint(Color(red: 0.18, green: 0.19, blue: 0.48))
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
                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("Enter text to translate…")
                            .foregroundStyle(.secondary).padding(16)
                    }
                    TextEditor(text: $inputText)
                        .frame(height: 140).opacity(inputText.isEmpty ? 0.25 : 1).padding(8)
                }
                .background(Color.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))

                Button("Translate to English") {}
                    .buttonStyle(.borderedProminent).tint(Color(red: 0.18, green: 0.19, blue: 0.48)).frame(maxWidth: .infinity)
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
                            Circle().fill(Color(red: 0.18, green: 0.19, blue: 0.48)).frame(width: 56, height: 56)
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
                        // .label includes the emoji: "🟢 Online" etc.
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
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { NetworkStatusChip() }
            }
        }
    }

    private func schemeBtn(_ label: String, _ value: String) -> some View {
        Button { schemePref = value } label: {
            Text(label)
                .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(schemePref == value ? Color(red: 0.18, green: 0.19, blue: 0.48) : Color.secondary.opacity(0.15))
                .foregroundStyle(schemePref == value ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - EmergencyView (always dark navy)

struct EmergencyView: View {
    @Binding var isPresented: Bool
    @StateObject private var detector = NetworkCountryDetector.shared
    @State private var pulse = false
    @State private var showLanguagePicker = false

    var body: some View {
        ZStack {
            Color(hex: "12153F").ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {

                    // ── Top bar: close (left) + language flag (right) ─────
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
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.2))
                            .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 12)

                    // ── Pulsing red dot ───────────────────────────────────
                    VStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Color.red.opacity(0.25))
                                .frame(width: pulse ? 72 : 50, height: pulse ? 72 : 50)
                                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                            Circle().fill(Color.red).frame(width: 20, height: 20)
                        }
                        Text("EMERGENCY ACCESS")
                            .font(.title2).fontWeight(.heavy)
                            .foregroundStyle(.white).tracking(2)
                    }
                    .onAppear { pulse = true }

                    // ── Patient card ──────────────────────────────────────
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Maria Kowalczyk")
                                    .font(.title3).fontWeight(.bold).foregroundStyle(.white)
                                Text("DOB: 12.08.1985 · Polish")
                                    .font(.subheadline).foregroundStyle(.white.opacity(0.65))
                            }
                            Spacer()
                            Text("A+").font(.title).fontWeight(.heavy).foregroundStyle(.red)
                        }

                        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("ALLERGIES")
                                .font(.caption2).fontWeight(.bold)
                                .foregroundStyle(Color.red).tracking(1.5)
                            HStack(spacing: 8) {
                                allergyBadge("Penicillin")
                                allergyBadge("Ibuprofen")
                                allergyBadge("Sulfa")
                            }
                        }

                        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("MEDICATIONS")
                                .font(.caption2).fontWeight(.bold)
                                .foregroundStyle(.white.opacity(0.5)).tracking(1.5)
                            medRow("Metformin",  "500mg", "2×/day")
                            medRow("Lisinopril", "10mg",  "1×/day")
                        }
                    }
                    .padding(20)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12)))
                    .padding(.horizontal, 16)

                    // ── Detection source label ────────────────────────────
                    Text(detector.current.sourceLabel)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))

                    // ── QR placeholder (works offline — local JWT) ─────────
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 160, height: 160)
                            .overlay(
                                Image(systemName: "qrcode")
                                    .font(.system(size: 80)).foregroundStyle(.white.opacity(0.4))
                            )
                        Text("Scan to access full medical record")
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                        Text("Works offline · Local JWT")
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
                    .padding(.horizontal, 16).padding(.bottom, 32)
                }
            }
        }
        // Language picker
        .confirmationDialog("Emergency Card Language", isPresented: $showLanguagePicker) {
            Button("🇺🇦 Ukrainian")  { detector.setManual(isoCode: "UA", language: "uk") }
            Button("🇩🇪 German")     { detector.setManual(isoCode: "DE", language: "de") }
            Button("🇵🇹 Portuguese") { detector.setManual(isoCode: "PT", language: "pt") }
            Button("🇬🇧 English")    { detector.setManual(isoCode: "GB", language: "en") }
            Button("Cancel", role: .cancel) {}
        }
        // Detect serving-network country on first open
        .task { await detector.detect() }
        // Scope dark mode to this view tree ONLY.
        // .environment(\.colorScheme, .dark) changes the SwiftUI environment
        // without touching UIWindow.overrideUserInterfaceStyle, so the rest
        // of the app is unaffected when this fullScreenCover is dismissed.
        .environment(\.colorScheme, .dark)
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

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(NetworkCountryDetector.shared)
}
