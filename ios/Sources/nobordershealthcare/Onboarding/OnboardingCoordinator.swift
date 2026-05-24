// OnboardingCoordinator.swift — State machine for the 5-step onboarding flow.
//
// Steps: welcome → registration → identity → userAgreement → emergencyContact → complete
//
// complete = true ONLY after all steps have been signed/completed.
// State persists across app restarts — interrupted onboarding resumes at correct step.
//
// Activation wizard keys (post-onboarding, shown in HomeView until all done):
//   wizardDoctorDone     — first-visit + family doctor questionnaire
//   wizardGuardianDone   — personal data + guardian documents upload
//   wizardInsuranceDone  — insurance policies verification

import SwiftUI

// MARK: - Steps

enum OnboardingStep: Int, Codable, CaseIterable {
    case welcome          = 0
    case registration     = 1
    case identity         = 2
    case userAgreement    = 3
    case emergencyContact = 4
    case complete         = 5

    var title: String {
        switch self {
        case .welcome:          return "Welcome"
        case .registration:     return "Your Account"
        case .identity:         return "Your Identity"
        case .userAgreement:    return "Agreement"
        case .emergencyContact: return "Emergency Contact"
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

    // Persisted across launches
    @AppStorage("onboardingComplete")             var complete: Bool = false
    @AppStorage("onboardingCurrentStep")          private var storedStep: Int = OnboardingStep.welcome.rawValue
    @AppStorage("onboardingRegistrationDone")     var registrationDone: Bool = false
    @AppStorage("onboardingIdentityDone")         var identityDone: Bool = false
    @AppStorage("onboardingUserAgreementDone")    var userAgreementDone: Bool = false
    @AppStorage("onboardingEmergencyContactDone") var emergencyContactDone: Bool = false

    // Activation wizard — shown in HomeView after onboarding until all done
    @AppStorage("wizardDoctorDone")    var wizardDoctorDone: Bool = false
    @AppStorage("wizardGuardianDone")  var wizardGuardianDone: Bool = false
    @AppStorage("wizardInsuranceDone") var wizardInsuranceDone: Bool = false

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
        case .welcome:
            currentStep = .registration
        case .registration:
            currentStep = registrationDone ? .identity : .registration
        case .identity:
            currentStep = identityDone ? .userAgreement : .identity
        case .userAgreement:
            currentStep = userAgreementDone ? .emergencyContact : .userAgreement
        case .emergencyContact:
            complete    = true
            currentStep = .complete
        case .complete:
            break
        }
        storedStep = currentStep.rawValue
    }

    func markRegistrationComplete() {
        registrationDone = true
        advance(from: .registration)
    }

    func markIdentityComplete() {
        identityDone = true
        advance(from: .identity)
    }

    func markUserAgreementComplete() {
        userAgreementDone = true
        advance(from: .userAgreement)
    }

    func markEmergencyContactComplete() {
        emergencyContactDone = true
        advance(from: .emergencyContact)
    }

    // MARK: - Legacy stubs (EmergencyCardSetupView / HealthcareProxyView / ConsentView / DataAuthorizationView)
    // These views are no longer part of the main onboarding flow but remain in the
    // codebase for use from Settings.  The stubs prevent compile errors.
    func markCardComplete()     {}
    func markProxyComplete()    {}
    func markConsentComplete()  {}
    func markDataAuthComplete() {}

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

    // MARK: - Activation wizard

    var wizardAllDone: Bool {
        wizardDoctorDone && wizardGuardianDone && wizardInsuranceDone
    }
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
                // Progress bar (hidden on welcome and complete)
                if coordinator.currentStep != .welcome && coordinator.currentStep != .complete {
                    progressBar
                }

                // Step content
                Group {
                    switch coordinator.currentStep {
                    case .welcome:
                        WelcomeView()
                    case .registration:
                        RegistrationView()
                    case .identity:
                        IdentityView()
                    case .userAgreement:
                        UserAgreementView()
                    case .emergencyContact:
                        EmergencyContactView()
                    case .complete:
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
