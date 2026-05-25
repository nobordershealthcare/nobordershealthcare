// ActivationCoordinator handles deep-link activation tokens from bulk-import invitations.
// Entry point: NoBordersHealthcareApp.onOpenURL → ActivationCoordinator.handleToken(_:)
//
// Flow:
//   1. Validate token with backend (POST /activate/validate)
//   2. Set ProfileType from server response
//   3. Pre-fill available fields (name, language) from server response
//   4. Route to correct onboarding path based on profile type
//
// SECURITY: token is a UUID v4 one-time secret — never log it, never store it after use.

import Foundation
import SwiftUI

@MainActor
final class ActivationCoordinator: ObservableObject {

    static let shared = ActivationCoordinator()

    @Published private(set) var pendingActivation: ActivationMeta? = nil

    private let validateEndpoint = URL(string: "https://api.noborders.health/activate/validate")!

    // MARK: - Deep link entry point

    func handleToken(_ token: String) {
        Task { await validate(token: token) }
    }

    // MARK: - Validation

    private func validate(token: String) async {
        guard token.count >= 32 else { return }  // UUID v4 minimum length guard

        var req = URLRequest(url: validateEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["token": token])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200
        else { return }

        guard let meta = try? JSONDecoder().decode(ActivationMeta.self, from: data) else { return }

        // Apply profile type from server response to Keychain
        ProfileTypeStore.shared.write(meta.profileType)

        pendingActivation = meta
    }

    // MARK: - Routing helper

    var onboardingStartStep: OnboardingStartStep {
        guard let meta = pendingActivation else { return .welcome }
        switch meta.profileType {
        case .military:      return .identity   // skip welcome; go straight to identity verification
        case .firstResponder: return .identity
        case .corporate, .family: return .registration
        case .civilian:      return .welcome
        }
    }
}

// MARK: - ActivationMeta

/// Server response from POST /activate/validate.
struct ActivationMeta: Codable {
    let profileType: ProfileType
    let language: String?          // ISO 639-1 — pre-sets app language
    let displayName: String?       // pre-fills registration form (corporate/family only)
    let planTier: String?
}

// MARK: - OnboardingStartStep

enum OnboardingStartStep {
    case welcome
    case registration
    case identity
}
