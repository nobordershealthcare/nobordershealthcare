// WelcomeView.swift — Step 1: Purpose statement and language selection.
//
// Single purpose: "Emergency eHR — receive medical care anywhere in the EU
// regardless of language or institutional barriers."
//
// Language selection is the ONLY configuration on this screen.
// No skip, no "later", no demo mode — the only CTA is "Get Started".
//
// Layout: ScrollView+pinned-button (no NavigationStack — OnboardingFlowView
// provides the outer container).  Language grid is LazyVGrid 2-col so it
// scales cleanly to 10+ locales without any scroll issue.

import SwiftUI

// MARK: - WelcomeView

struct WelcomeView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @AppStorage("appLanguage") private var appLanguage: String = "en"

    // ── Language catalogue — add new locales here only ──────────────────────
    // Launch-required: en · uk · de · pt · ar
    // Interface + translation only (not launch-blocking): ru + EU locales
    private let supportedLanguages: [(code: String, name: String, flag: String)] = [
        // ── Launch languages ───────────────────────────────────────────────
        ("en", "English",    "🇬🇧"),
        ("uk", "Українська", "🇺🇦"),
        ("de", "Deutsch",    "🇩🇪"),
        ("pt", "Português",  "🇵🇹"),
        ("ar", "العربية",    "🇸🇦"),
        // ── EU expansion ──────────────────────────────────────────────────
        ("fr", "Français",   "🇫🇷"),
        ("es", "Español",    "🇪🇸"),
        ("it", "Italiano",   "🇮🇹"),
        ("pl", "Polski",     "🇵🇱"),
        ("nl", "Nederlands", "🇳🇱"),
        ("ro", "Română",     "🇷🇴"),
        ("cs", "Čeština",    "🇨🇿"),
        ("sv", "Svenska",    "🇸🇪"),
        ("no", "Norsk",      "🇳🇴"),
        ("fi", "Suomi",      "🇫🇮"),
        // ── Interface + document translation only ─────────────────────────
        ("ru", "Русский",    "🇷🇺"),
    ]

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var continueButtonTitle: String {
        switch appLanguage {
        case "uk": return "Розпочати"
        case "de": return "Loslegen"
        case "pt": return "Começar"
        case "ar": return "ابدأ"
        case "fr": return "Commencer"
        case "es": return "Empezar"
        case "it": return "Inizia"
        case "pl": return "Rozpocznij"
        case "nl": return "Starten"
        case "ro": return "Începe"
        case "cs": return "Začít"
        case "sv": return "Börja"
        case "no": return "Kom i gang"
        case "fi": return "Aloita"
        case "ru": return "Начать"
        default:   return "Get Started"
        }
    }

    var body: some View {
        // No NavigationStack — OnboardingFlowView is the container
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // ── Logo + Brand ───────────────────────────────────────
                    logoSection

                    // ── Purpose statement ─────────────────────────────────
                    purposeStatement
                        .padding(.top, 8)

                    // ── Language grid ─────────────────────────────────────
                    languageGrid
                        .padding(.top, 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            // ── CTA — pinned to bottom, always visible ─────────────────
            Button {
                coordinator.advance(from: .welcome)
            } label: {
                Text(continueButtonTitle)
                    .font(.headline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.navy)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 36)
        }
        .background(Color.appBg.ignoresSafeArea())
    }

    // MARK: - Sections

    private var logoSection: some View {
        VStack(spacing: 8) {
            Image("NBHC logo")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)

            Text("Emergency eHR Wallet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var purposeStatement: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Emergency Health Identity")
                .font(.title3)
                .fontWeight(.bold)

            Text("Receive medical care anywhere in the EU regardless of language or institutional barriers. Your critical health data — allergies, medications, blood type — available to emergency doctors in seconds, in their language, offline.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Language grid

    private var languageGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select your language")
                .font(.subheadline)
                .fontWeight(.semibold)

            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(supportedLanguages, id: \.code) { lang in
                    languageCell(lang)
                }
            }
        }
    }

    private func languageCell(_ lang: (code: String, name: String, flag: String)) -> some View {
        let selected = appLanguage == lang.code
        let isRTL    = lang.code == "ar"
        return Button {
            appLanguage = lang.code
            applyLocale(lang.code)
        } label: {
            HStack(spacing: 8) {
                // For RTL languages: checkmark leads, then name, then flag
                if isRTL {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.navy)
                    }
                    Text(lang.name)
                        .font(.subheadline)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Color.navy : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .environment(\.layoutDirection, .rightToLeft)
                    Spacer(minLength: 0)
                    Text(lang.flag).font(.title3)
                } else {
                    Text(lang.flag).font(.title3)
                    Text(lang.name)
                        .font(.subheadline)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Color.navy : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.navy)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                selected
                    ? Color.navy.opacity(0.10)
                    : Color(.secondarySystemGroupedBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selected ? Color.navy.opacity(0.4) : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Locale application

    /// Writes the selection and triggers environment locale reload.
    private func applyLocale(_ code: String) {
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        // Views reading @AppStorage("appLanguage") re-render immediately.
        // Full system locale restart happens on next launch for system strings.
    }
}

#Preview {
    WelcomeView()
        .environmentObject(OnboardingCoordinator())
}
