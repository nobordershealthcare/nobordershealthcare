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

    // Onboarding gate — complete = true only after all 7 steps signed.
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some Scene {
        WindowGroup {
            if onboardingComplete {
                ContentView()
                    .environmentObject(detector)
                    .preferredColorScheme(resolvedScheme)
            } else {
                OnboardingFlowView()
                    .environmentObject(detector)
                    .preferredColorScheme(resolvedScheme)
            }
        }
    }
}
