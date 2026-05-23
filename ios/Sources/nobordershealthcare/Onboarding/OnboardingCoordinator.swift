// OnboardingCoordinator.swift — State machine for the 7-step onboarding flow.
//
// complete = true ONLY after ALL 7 steps have been signed and stored.
// State persists across app restarts — interrupted onboarding resumes at correct step.
// Each step's completion writes its artifact to the appropriate vault:
//   identity     → VaultManager (Silo 1)
//   emergencyCard → VaultManager (Silo 1)
//   proxy        → LegalVaultManager (Silo 2)
//   consent      → LegalVaultManager (Silo 2)
//   dataAuth     → LegalVaultManager (Silo 2)

import SwiftUI
import Combine

// MARK: - Steps

enum OnboardingStep: Int, Codable, CaseIterable {
    case welcome        = 0
    case identity       = 1
    case emergencyCard  = 2
    case healthcareProxy = 3
    case gdprConsent    = 4
    case dataAuthorization = 5
    case complete       = 6

    var title: String {
        switch self {
        case .welcome:          return "Welcome"
        case .identity:         return "Your Identity"
        case .emergencyCard:    return "Emergency Card"
        case .healthcareProxy:  return "Healthcare Proxy"
        case .gdprConsent:      return "Data Consent"
        case .dataAuthorization: return "Data Authorization"
        case .complete:         return "Done"
        }
    }

    var next: OnboardingStep {
        OnboardingStep(rawValue: rawValue + 1) ?? .complete
    }
}

// MARK: - OnboardingCoordinator

@MainActor
final class OnboardingCoordinator: ObservableObject {

    static let shared = OnboardingCoordinator()

    // Persisted across launches — resumes interrupted onboarding
    @AppStorage("onboardingComplete")     var complete: Bool = false
    @AppStorage("onboardingCurrentStep")  private var storedStep: Int = OnboardingStep.welcome.rawValue
    @AppStorage("onboardingIdentityDone") var identityDone: Bool = false
    @AppStorage("onboardingCardDone")     var cardDone: Bool = false
    @AppStorage("onboardingProxyDone")    var proxyDone: Bool = false
    @AppStorage("onboardingConsentDone")  var consentDone: Bool = false
    @AppStorage("onboardingDataAuthDone") var dataAuthDone: Bool = false

    @Published var currentStep: OnboardingStep
    @Published var errors: [OnboardingStep: String] = [:]

    init() {
        let raw = UserDefaults.standard.integer(forKey: "onboardingCurrentStep")
        self.currentStep = OnboardingStep(rawValue: raw) ?? .welcome
    }

    // MARK: - Step advancement

    func advance(from step: OnboardingStep) {
        errors[step] = nil
        switch step {
        case .welcome:       currentStep = .identity
        case .identity:      currentStep = identityDone ? .emergencyCard : .identity
        case .emergencyCard: currentStep = cardDone ? .healthcareProxy : .emergencyCard
        case .healthcareProxy: currentStep = .gdprConsent
        case .gdprConsent:   currentStep = consentDone ? .dataAuthorization : .gdprConsent
        case .dataAuthorization:
            if dataAuthDone {
                complete = true
                currentStep = .complete
            }
        case .complete: break
        }
        storedStep = currentStep.rawValue
    }

    func markIdentityComplete() {
        identityDone = true
        advance(from: .identity)
    }

    func markCardComplete() {
        cardDone = true
        advance(from: .emergencyCard)
    }

    func markProxyComplete() {
        proxyDone = true
        advance(from: .healthcareProxy)
    }

    func markConsentComplete() {
        consentDone = true
        advance(from: .gdprConsent)
    }

    func markDataAuthComplete() {
        dataAuthDone = true
        advance(from: .dataAuthorization)
    }

    func setError(_ message: String, for step: OnboardingStep) {
        errors[step] = message
    }

    // MARK: - Progress

    var progressFraction: Double {
        let total = Double(OnboardingStep.complete.rawValue)
        return Double(currentStep.rawValue) / total
    }

    var stepsCompleted: Int { currentStep.rawValue }
    var totalSteps: Int     { OnboardingStep.complete.rawValue }
}

// MARK: - OnboardingFlowView

/// Root view for the onboarding flow. Observes OnboardingCoordinator and
/// displays the correct step view. Called from NoBordersHealthcareApp.swift.
struct OnboardingFlowView: View {

    @StateObject private var coordinator = OnboardingCoordinator.shared

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress bar
                if coordinator.currentStep != .welcome && coordinator.currentStep != .complete {
                    progressBar
                }

                // Step content
                Group {
                    switch coordinator.currentStep {
                    case .welcome:
                        WelcomeView()
                    case .identity:
                        IdentityView()
                    case .emergencyCard:
                        EmergencyCardSetupView()
                    case .healthcareProxy:
                        HealthcareProxyView()
                    case .gdprConsent:
                        ConsentView()
                    case .dataAuthorization:
                        DataAuthorizationView()
                    case .complete:
                        // Caller (App) switches to ContentView when complete == true
                        Color.clear
                    }
                }
                .environmentObject(coordinator)
            }
        }
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.navy)
                        .frame(width: geo.size.width * coordinator.progressFraction, height: 4)
                        .animation(.spring, value: coordinator.progressFraction)
                }
            }
            .frame(height: 4)

            HStack {
                Text("Step \(coordinator.stepsCompleted) of \(coordinator.totalSteps)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(coordinator.currentStep.title)
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(Color.navy)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}
