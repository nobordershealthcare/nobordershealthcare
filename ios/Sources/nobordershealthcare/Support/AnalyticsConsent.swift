// AnalyticsConsent.swift — Optional analytics collection with explicit GDPR consent.
//
// Two legal bases — kept strictly separate:
//
//   "Always On" (GDPR Art.6(1)(f) — legitimate interest):
//     • Security monitoring (DeviceSecurityProfile) — see SecurityProfile.swift
//     This block cannot be toggled off; it is necessary to protect the wallet.
//
//   "Optional analytics" (GDPR Art.6(1)(a) — explicit consent):
//     • preferredLanguage, profileTypeAnon, countryRegion (ISO code, not GPS)
//     • featureUsage — which features are tapped (anonymised event names only)
//     • appVersion, onboardingCompletedSteps
//     Default: OFF. Patient must affirmatively opt in.
//     Withdrawal: immediate data deletion (Art.7(3)).
//
// What is NEVER collected regardless of consent:
//   • Name, email, phone, DOB, national ID — any PII
//   • Medical data (diagnoses, medications, lab values)
//   • Device hardware IDs (IMEI, UDID, serial number, IDFA)
//   • Precise GPS location or IP address
//   • List of other installed apps
//
// AnalyticsConsentView is shown ONCE after onboarding completes.
// AppStorage "analyticsConsentShown" gates whether the sheet appears.
//
// Storage: UserDefaults "com.noborders.analytics.consent"
//   Not Keychain — this data is not sensitive (consent flag + anonymised prefs).
//   Health data always stays in Silo 1 (Keychain/Secure Enclave).

import Foundation
import SwiftUI

// MARK: - AnalyticsProfile

struct AnalyticsProfile: Codable, Sendable {

    // Consent
    var consentGiven: Bool
    var consentTimestamp: Date?
    var consentVersion: String     // Bumped when data collection scope changes.
                                    // A new consent prompt is shown on version change.

    // Non-sensitive analytics fields — collected only when consentGiven == true
    var preferredLanguage: String        // BCP-47 tag, e.g. "pl", "de", "uk"
    var profileTypeAnon: String          // "civilian" / "military" / "first_responder" — no name
    var countryRegion: String            // ISO 3166-1 alpha-2, e.g. "DE" — NOT GPS, NOT IP
    var featureUsage: [String: Int]      // e.g. ["emergency_qr": 3, "translate": 7]
    var appVersion: String               // CFBundleShortVersionString
    var onboardingCompletedSteps: Int    // 0-3 — measures funnel completion

    // MARK: - Defaults

    static let currentConsentVersion = "1.0"

    static var empty: AnalyticsProfile {
        AnalyticsProfile(
            consentGiven: false,
            consentTimestamp: nil,
            consentVersion: currentConsentVersion,
            preferredLanguage: Locale.current.language.languageCode?.identifier ?? "en",
            profileTypeAnon: "civilian",
            countryRegion: "XX",
            featureUsage: [:],
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0",
            onboardingCompletedSteps: 0
        )
    }

    // MARK: - Mutations (only safe to call when consentGiven == true)

    mutating func recordFeatureUse(_ feature: String) {
        guard consentGiven else { return }
        featureUsage[feature, default: 0] += 1
    }

    mutating func grant() {
        consentGiven = true
        consentTimestamp = Date()
        consentVersion = Self.currentConsentVersion
    }

    /// Withdraw consent — immediately clears all collected analytics data (Art.7(3)).
    mutating func withdraw() {
        consentGiven = false
        consentTimestamp = nil
        preferredLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        profileTypeAnon = "civilian"
        countryRegion = "XX"
        featureUsage = [:]
        onboardingCompletedSteps = 0
        // appVersion and consentVersion are retained to detect future scope changes.
    }
}

// MARK: - AnalyticsConsentStore

/// UserDefaults persistence for AnalyticsProfile.
/// Key: "com.noborders.analytics.consent" — NOT Keychain (not sensitive).
enum AnalyticsConsentStore {

    private static let key = "com.noborders.analytics.consent"

    static func save(_ profile: AnalyticsProfile) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> AnalyticsProfile {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return .empty
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(AnalyticsProfile.self, from: data)) ?? .empty
    }

    /// Wipe all analytics data immediately (GDPR Art.7(3) withdrawal).
    static func delete() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - AnalyticsConsentView

/// Shown ONCE after onboarding. Both paths (accept / decline) allow the user to proceed.
/// Default: analytics OFF. Patient must affirmatively tap "Accept analytics."
struct AnalyticsConsentView: View {

    @Environment(\.dismiss) private var dismiss

    /// Called with the final profile when the user makes a choice.
    var onDecision: (AnalyticsProfile) -> Void

    @State private var analyticsToggle: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // ── Header ─────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "chart.bar.doc.horizontal")
                                .font(.largeTitle)
                                .foregroundStyle(Color.navy)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Help us improve")
                                    .font(.title2).fontWeight(.bold)
                                Text("Your choice. Your data.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Text("We need your explicit permission before collecting any usage data. You can change this at any time in Profile → Privacy & Analytics.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    // ── Always-on block ────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Always on (no opt-out)", systemImage: "lock.shield.fill")
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.primary)

                        privacyRow(
                            icon: "shield.fill", tint: .green,
                            title: "Security monitoring",
                            detail: "Device fingerprint hash, failed auth count — protects your wallet from cloning and takeover. Legal basis: Art.6(1)(f) legitimate interest."
                        )
                    }
                    .padding(14)
                    .background(Color.green.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.25), lineWidth: 1)
                    )

                    // ── Optional block ─────────────────────────────────────
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Optional analytics", systemImage: "chart.bar.fill")
                                .font(.subheadline).fontWeight(.semibold)
                            Spacer()
                            Toggle("", isOn: $analyticsToggle)
                                .labelsHidden()
                                .tint(Color.navy)
                        }

                        Text("Helps us fix crashes and improve features. Default: off.")
                            .font(.caption).foregroundStyle(.secondary)

                        Divider()

                        Group {
                            privacyRow(
                                icon: "globe", tint: .blue,
                                title: "Country & language",
                                detail: "ISO country code (e.g. \"DE\") and your app language. Not your GPS location or IP."
                            )
                            privacyRow(
                                icon: "hand.tap.fill", tint: .orange,
                                title: "Feature usage",
                                detail: "Which features you tap (e.g. \"emergency_qr\", \"translate\"). No content, no medical data."
                            )
                            privacyRow(
                                icon: "app.fill", tint: Color(red: 0.5, green: 0.2, blue: 0.9),
                                title: "App version & onboarding progress",
                                detail: "Helps us understand which version you're on and whether setup completed."
                            )
                        }

                        Divider()

                        // What we never collect
                        VStack(alignment: .leading, spacing: 6) {
                            Text("We NEVER collect:")
                                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                            neverRow("Name, email, phone, or date of birth")
                            neverRow("Medical data, diagnoses, medications")
                            neverRow("Device IMEI, UDID, serial number, or advertising ID")
                            neverRow("Precise GPS location or IP address")
                        }
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                    // ── Action buttons ─────────────────────────────────────
                    VStack(spacing: 10) {
                        Button {
                            var profile = buildProfile(consent: analyticsToggle)
                            if analyticsToggle { profile.grant() }
                            AnalyticsConsentStore.save(profile)
                            UserDefaults.standard.set(true, forKey: "analyticsConsentShown")
                            onDecision(profile)
                            dismiss()
                        } label: {
                            Text(analyticsToggle ? "Accept analytics" : "Use without analytics")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.navy)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        Text("You can withdraw consent at any time. All optional data is deleted immediately on withdrawal.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.appBg.ignoresSafeArea())
            .navigationTitle("Privacy choices")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Helpers

    private func buildProfile(consent: Bool) -> AnalyticsProfile {
        var p = AnalyticsConsentStore.load()
        p.preferredLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        p.countryRegion = NetworkCountryDetector.shared.current.isoCode
        p.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return p
    }

    private func privacyRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func neverRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - PrivacyAnalyticsManagementView

/// Accessible from Profile → Privacy & Analytics.
/// Lets patients review their consent status and withdraw at any time.
struct PrivacyAnalyticsManagementView: View {

    @State private var profile: AnalyticsProfile = AnalyticsConsentStore.load()
    @State private var showWithdrawConfirm = false

    var body: some View {
        List {

            // ── Always-on section ──────────────────────────────────────────
            Section {
                HStack {
                    Label("Security monitoring", systemImage: "shield.fill")
                    Spacer()
                    Text("Always on").font(.caption).foregroundStyle(.secondary)
                }
                Text("Required to detect wallet cloning and account takeover. Legal basis: GDPR Art.6(1)(f).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Always active")
            }

            // ── Optional analytics section ─────────────────────────────────
            Section {
                HStack {
                    Label("Usage analytics", systemImage: "chart.bar.fill")
                    Spacer()
                    Image(systemName: profile.consentGiven ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(profile.consentGiven ? Color.green : Color.secondary)
                }
                if let ts = profile.consentTimestamp {
                    HStack {
                        Text("Consented")
                        Spacer()
                        Text(ts.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if profile.consentGiven {
                    Button(role: .destructive) {
                        showWithdrawConfirm = true
                    } label: {
                        Label("Withdraw consent & delete data", systemImage: "trash.fill")
                    }
                }
            } header: {
                Text("Optional analytics")
            } footer: {
                Text("Collected: country, language, feature taps, app version.\nNever: medical data, name, IDs, or precise location.")
            }

            // ── Feature usage summary (visible when consent given) ─────────
            if profile.consentGiven && !profile.featureUsage.isEmpty {
                Section("Feature usage (this device)") {
                    ForEach(profile.featureUsage.sorted(by: { $0.value > $1.value }), id: \.key) { kv in
                        HStack {
                            Text(kv.key).font(.caption)
                            Spacer()
                            Text("\(kv.value)×").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Privacy & Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Withdraw consent?",
            isPresented: $showWithdrawConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all analytics data", role: .destructive) {
                profile.withdraw()
                AnalyticsConsentStore.save(profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All optional usage data will be deleted immediately from this device. You can re-enable analytics at any time.")
        }
        .onAppear { profile = AnalyticsConsentStore.load() }
    }
}
