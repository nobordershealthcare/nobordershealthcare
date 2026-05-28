//
//  NoBordersHealthcareApp.swift
//  nobordershealthcare
//

import SwiftUI

@main
struct NoBordersHealthcareApp: App {

    // Shared singleton — @MainActor + ObservableObject, owns the NWPathMonitor.
    // Injected as @EnvironmentObject so all tabs can read network + country state.
    @StateObject private var detector = NetworkCountryDetector.shared

    // User-facing colour-scheme preference (mirrors ProfileView's @AppStorage).
    // "auto" → nil → follows iOS system.  "light"/"dark" → override.
    @AppStorage("colorScheme") private var schemePref: String = "auto"

    private var resolvedScheme: ColorScheme? {
        switch schemePref {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // .preferredColorScheme(nil) = follow system
        }
    }

    // Onboarding gate — complete = true only after all steps are done.
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    // Biometric gate — set to true automatically when the user signs the
    // User Agreement in onboarding.  After that every launch + foreground
    // resume requires a successful biometric challenge.
    @AppStorage("biometricLockEnabled") private var biometricLockEnabled = false

    // Tracks whether the current session has passed the biometric challenge.
    // Reset to false whenever the app moves to the background so BiometricLockView
    // is shown again on the next foreground resume.
    @State private var isUnlocked = false

    @StateObject private var activationCoordinator = ActivationCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingComplete && biometricLockEnabled && !isUnlocked {
                    // ── Biometric gate ─────────────────────────────────────
                    BiometricLockView { isUnlocked = true }
                        .preferredColorScheme(resolvedScheme)
                } else if onboardingComplete {
                    // ── Main app ───────────────────────────────────────────
                    ContentView()
                        .environmentObject(detector)
                        .preferredColorScheme(resolvedScheme)
                } else {
                    // ── Onboarding flow ────────────────────────────────────
                    OnboardingFlowView()
                        .environmentObject(detector)
                        .environmentObject(activationCoordinator)
                        .preferredColorScheme(resolvedScheme)
                }
            }
            .onOpenURL { url in
                // ── Diia App Switch callback ──────────────────────────────────────
                // nobordershealthcare://diia-callback?payload=<JWT>
                // DiiaService handles it and updates its @Published state;
                // IdentityView observes that change via @ObservedObject.
                if DiiaService.shared.handleCallback(url: url) != nil { return }

                // ── Activation deep link ──────────────────────────────────────────
                // Deep link: {APP_BASE_URL}/activate/{token} — host from AppConfig (never hardcoded)
                // Token is UUID v4 — never log, never store after use.
                guard url.host == AppConfig.appHost,
                      url.path.hasPrefix("/activate/")
                else { return }
                let token = String(url.path.dropFirst("/activate/".count))
                Task { await activationCoordinator.handleToken(token) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-lock the app the moment it leaves the foreground.
            // BiometricLockView will prompt again on the next foreground resume.
            if phase == .background {
                isUnlocked = false
            }
        }
    }
}
