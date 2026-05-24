// WelcomeView.swift — Step 1: Purpose statement and language selection.
//
// Single purpose: "Emergency eHR — receive medical care anywhere in the EU
// regardless of language or institutional barriers."
//
// Language selection is the ONLY configuration on this screen.
// No skip, no "later", no demo mode — the only CTA is "Begin Emergency eHR Setup".

import SwiftUI

// MARK: - WelcomeView

struct WelcomeView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @AppStorage("appLanguage") private var appLanguage: String = "en"

    private let supportedLanguages: [(code: String, name: String, flag: String)] = [
        ("en", "English",    "🇬🇧"),
        ("uk", "Українська", "🇺🇦"),
        ("de", "Deutsch",    "🇩🇪"),
        ("pt", "Português",  "🇵🇹"),
        ("ru", "Русский",    "🇷🇺"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 40) {
                    Spacer(minLength: 32)

                    // ── Logo + Brand ───────────────────────────────────────────
                    logoSection

                    // ── Purpose statement ──────────────────────────────────────
                    purposeStatement

                    // ── Language picker ────────────────────────────────────────
                    languagePicker

                    Spacer(minLength: 32)

                    // ── CTA ────────────────────────────────────────────────────
                    beginButton
                }
                .padding(.horizontal, 24)
            }
            .navigationBarHidden(true)
        }
    }

    // MARK: - Sections

    private var logoSection: some View {
        VStack(spacing: 16) {
            Image("NBHC logo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)

            VStack(spacing: 6) {
                Text("#nobordershealthcare")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.navy)
                Text("Emergency eHR Wallet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var purposeStatement: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Emergency Health Identity")
                .font(.title3)
                .fontWeight(.bold)

            Text("Receive medical care anywhere in the EU regardless of language or institutional barriers. Your critical health data — allergies, medications, blood type — available to emergency doctors in seconds, in their language, offline.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.navy)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Patient-controlled, GDPR Art.9")
                        .font(.subheadline).fontWeight(.semibold)
                    Text("Only you control who sees your data. All processing on-device. EU law applies.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select your language")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(spacing: 0) {
                ForEach(supportedLanguages, id: \.code) { lang in
                    Button {
                        appLanguage = lang.code
                        applyLocale(lang.code)
                    } label: {
                        HStack {
                            Text(lang.flag)
                                .font(.title2)
                            Text(lang.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            if appLanguage == lang.code {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.navy)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if lang.code != supportedLanguages.last?.code {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var beginButton: some View {
        Button {
            coordinator.advance(from: .welcome)
        } label: {
            Text("Begin Emergency eHR Setup")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.navy)
        .padding(.bottom, 24)
    }

    // MARK: - Locale application

    /// Writes the selection and triggers environment locale reload.
    private func applyLocale(_ code: String) {
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        // Views reading @AppStorage("appLanguage") will re-render immediately.
        // Full system locale restart happens on next launch for system strings.
    }
}

#Preview {
    WelcomeView()
        .environmentObject(OnboardingCoordinator())
}
