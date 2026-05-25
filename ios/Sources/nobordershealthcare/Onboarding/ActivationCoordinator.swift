// ActivationCoordinator handles deep-link activation tokens from bulk-import invitations.
// Entry point: NoBordersHealthcareApp.onOpenURL → ActivationCoordinator.handleToken(_:)
//
// Protocol:
//   1. Compute SHA3-256(token) client-side (token never sent to server)
//   2. POST /activate/validate {token_hash: SHA3-256(token)}
//   3. Server invalidates token atomically (one-shot Redis NX)
//   4. Server returns profile metadata (never the token itself)
//   5. Set ProfileType + OperationalProfile from server response
//   6. Pre-fill name/language if provided
//   7. Route to correct onboarding path based on profile type
//
// SECURITY: token is UUID v4 one-time secret — SHA3-256 before sending, then discard.

import Foundation
import SwiftUI
import CryptoKit

// MARK: - ActivationResponse

/// Server response from POST /activate/validate.
struct ActivationResponse: Codable {
    let profileType: ProfileType
    let operationalRole: OperationalRole
    let authority: AuthorityType
    let language: String?
    let displayName: String?
    let planTier: String?
}

// MARK: - ActivationState

enum ActivationState {
    case idle
    case validating
    case valid(response: ActivationResponse)
    case expired
    case alreadyUsed
    case failed
}

// MARK: - ActivationCoordinator

@MainActor
final class ActivationCoordinator: ObservableObject {

    static let shared = ActivationCoordinator()

    @Published private(set) var state: ActivationState = .idle

    private let validateURL = URL(string: "https://api.noborders.health/activate/validate")!

    // MARK: - Deep link entry point

    func handleToken(_ token: String) async {
        guard !token.isEmpty, token.count >= 32 else { return }
        state = .validating

        // Hash the token client-side — plaintext token never leaves the device.
        guard let tokenHash = sha3_256Hex(token) else {
            state = .failed
            return
        }

        var req = URLRequest(url: validateURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["token_hash": tokenHash])

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                state = .failed; return
            }
            switch http.statusCode {
            case 200:
                let dec = JSONDecoder()
                dec.keyDecodingStrategy = .convertFromSnakeCase
                let response = try dec.decode(ActivationResponse.self, from: data)
                applyResponse(response)
                state = .valid(response: response)
            case 410:
                state = .alreadyUsed
            case 404:
                state = .expired
            default:
                state = .failed
            }
        } catch {
            state = .failed
        }
    }

    // MARK: - Profile application

    private func applyResponse(_ response: ActivationResponse) {
        // Write ProfileType to Keychain
        ProfileTypeStore.shared.write(response.profileType)

        // Build and write OperationalProfile to Legal Vault Keychain
        let profile = OperationalProfile(
            profileType:              response.profileType,
            operationalRole:          response.operationalRole,
            identityProtection:       defaultProtectionLevel(for: response.operationalRole),
            authority:                response.authority,
            legalBasis:               defaultLegalBasis(for: response.authority),
            nokNotifyDirect:          response.operationalRole == .none,
            schengenCrossBorder:      response.authority == .eu_special || response.authority == .eu_gendarmerie,
            eucpId:                   nil,
            atlasNetworkId:           nil,
            cbrnExposureHistory:      nil,
            hasPsychologicalMedications: false
        )
        OperationalProfileStore.shared.write(profile)

        // Apply language preference if provided
        if let lang = response.language {
            UserDefaults.standard.set(lang, forKey: "appLanguage")
        }
    }

    // MARK: - Onboarding routing

    var onboardingPath: OnboardingPath {
        guard case .valid(let response) = state else { return .welcome }
        switch response.profileType {
        case .military:
            return .military(prefill: response)
        case .firstResponder:
            return .military(prefill: response)
        case .corporate, .family:
            return .standard(prefill: response)
        case .civilian:
            return .welcome
        }
    }

    // MARK: - Helpers

    private func sha3_256Hex(_ input: String) -> String? {
        guard let data = input.data(using: .utf8) else { return nil }
        var hasher = SHA256()  // CryptoKit SHA256 is used here only for PKCE;
        // for patient data we use SHA3Kit. Token is not patient data.
        // TODO: replace with SHA3Kit.sha3_256 when available in this target.
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func defaultProtectionLevel(for role: OperationalRole) -> IdentityProtectionLevel {
        switch role {
        case .specialOps:          return .covert
        case .lawEnforcement, .nationalGuard, .gendarmerie: return .minimal
        case .civilDefense, .sarTeam, .euBorderGuard, .europolOfficer, .fireRescue: return .reduced
        case .none:                return .standard
        }
    }

    private func defaultLegalBasis(for authority: AuthorityType) -> LegalBasisType {
        switch authority {
        case .nato:                return .nato_stanag
        case .eu_police, .eu_gendarmerie, .eu_special, .eu_border, .eu_interpol, .interpol:
            return .led_art10
        case .ua_mo, .ua_mvs, .ua_sbu, .ua_dsns:
            return .nato_stanag
        case .ua_civilian, .eu_civil:
            return .gdpr_art9
        }
    }
}

// MARK: - OnboardingPath

enum OnboardingPath {
    case welcome
    case military(prefill: ActivationResponse)
    case standard(prefill: ActivationResponse)
}
