// Offline emergency QR scope token.
// JWT: EdDSA (Ed25519), 15-min TTL, self-verifying (public key embedded in `pk` claim).
// Signed only in foreground — background signing is intentionally disabled.
// Token is stored in the App Group Keychain so EmergencyWidget can display it without unlock.
// Expiry countdown and red warning at <2 min are state emitted via TokenState.

import Foundation
import CryptoKit
import Security
import SHA3Kit

// MARK: - Token state

enum TokenState: Sendable {
    case valid(secondsRemaining: Int)
    case expiringSoon(secondsRemaining: Int)  // < 120 seconds
    case expired
}

// MARK: - JWT scope token

struct ScopedJWT: Sendable, Codable {
    let rawToken: String        // complete signed JWT string
    let expiresAt: Date
    let jti: String             // for revocation
    let publicKeyBase64: String // Ed25519 public key, base64url-encoded (ER doc can verify offline)
}

// MARK: - EmergencyCard actor

actor EmergencyCard {

    static let shared = EmergencyCard()

    private let appGroupID       = "group.com.noborders.emergency"
    private let tokenKeychainKey = "com.noborders.token.scoped-jwt"
    private var currentToken: ScopedJWT?

    enum CardError: Error {
        case noActiveDID
        case signingFailed(Error)
        case keychainFailed(OSStatus)
        case notAuthenticated
    }

    // MARK: - Token issuance (foreground only)

    // Call from foreground context whenever the token is near expiry or revoked.
    func issueToken(for userIDHash: String, composition: Composition) async throws -> ScopedJWT {
        let scope = try await ScopeManager.shared.currentScope()
        let filtered = IPS.applyScope(to: composition, scope: scope.asIPSFilter)
        let ipsSubset = extractSubset(from: filtered, hash: userIDHash)

        let pubKeyData = try await KeyManager.shared.ed25519PublicKeyData()
        let pubKeyB64  = pubKeyData.base64URLEncodedString()

        let jti = UUID().uuidString.lowercased()
        let iat = Date()
        let exp = iat.addingTimeInterval(900)  // 15 minutes

        let header  = try base64url(json: ["alg": "EdDSA", "typ": "JWT"])
        let payload = try base64url(json: [
            "sub":   userIDHash,
            "pk":    pubKeyB64,
            "scope": scopeArray(from: scope),
            "ips":   encodeSubset(ipsSubset),
            "iat":   Int(iat.timeIntervalSince1970),
            "exp":   Int(exp.timeIntervalSince1970),
            "jti":   jti,
        ])

        let signingInput = Data("\(header).\(payload)".utf8)
        let signature: Data
        do {
            signature = try await KeyManager.shared.sign(signingInput)
        } catch {
            throw CardError.signingFailed(error)
        }

        let rawToken = "\(header).\(payload).\(signature.base64URLEncodedString())"
        let token = ScopedJWT(rawToken: rawToken, expiresAt: exp, jti: jti, publicKeyBase64: pubKeyB64)

        try storeToken(token)
        currentToken = token
        return token
    }

    // MARK: - Token access

    func loadCurrentToken() throws -> ScopedJWT {
        if let t = currentToken { return t }
        return try loadStoredToken()
    }

    func tokenState() throws -> TokenState {
        let token = try loadCurrentToken()
        let remaining = Int(token.expiresAt.timeIntervalSinceNow)
        if remaining <= 0   { return .expired }
        if remaining <= 120 { return .expiringSoon(secondsRemaining: remaining) }
        return .valid(secondsRemaining: remaining)
    }

    func isExpired() throws -> Bool {
        if case .expired = try tokenState() { return true }
        return false
    }

    // MARK: - Revocation

    // Issues a new token (new jti), invalidating the previous one.
    // Caller must send the old jti to the backend revocation endpoint.
    func revoke(composition: Composition, userIDHash: String) async throws -> (newToken: ScopedJWT, oldJTI: String) {
        let oldJTI = (try? loadCurrentToken())?.jti ?? ""
        deleteStoredToken()
        currentToken = nil
        let newToken = try await issueToken(for: userIDHash, composition: composition)
        return (newToken, oldJTI)
    }

    // MARK: - App Group Keychain (shared with EmergencyWidget)

    private func storeToken(_ token: ScopedJWT) throws {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let q: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      tokenKeychainKey,
            kSecAttrAccessGroup as String:  appGroupID,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw CardError.keychainFailed(status) }
    }

    private func loadStoredToken() throws -> ScopedJWT {
        let q: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      tokenKeychainKey,
            kSecAttrAccessGroup as String:  appGroupID,
            kSecReturnData as String:       true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw CardError.keychainFailed(status)
        }
        return try JSONDecoder().decode(ScopedJWT.self, from: data)
    }

    private func deleteStoredToken() {
        let q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     tokenKeychainKey,
            kSecAttrAccessGroup as String: appGroupID,
        ]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - JWT helpers

    // Throws rather than force-try: non-JSON-serializable values in `json`
    // (e.g. a non-primitive type accidentally passed as a claim value) would
    // crash the app at the moment the emergency QR is being minted.
    // Callers propagate the error up to issueToken(), which already throws.
    private func base64url(json: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: json)
        return data.base64URLEncodedString()
    }

    private func scopeArray(from scope: EmergencyScope) -> [String] {
        var s: [String] = []
        if scope.includeAllergies   { s.append("allergies") }
        if scope.includeMedications { s.append("medications") }
        if scope.includeConditions  { s.append("conditions") }
        if scope.includeBloodGroup  { s.append("blood_group") }
        if scope.includeLabResults  { s.append("lab_results") }
        return s
    }

    private func extractSubset(from composition: Composition, hash: String) -> IPSEmergencySubset {
        var allergies:   [AllergyEntry]    = []
        var medications: [MedicationEntry] = []
        var conditions:  [ConditionEntry]  = []

        for section in composition.sections {
            for entry in section.entries {
                switch entry {
                case .allergy(let a):    allergies.append(a)
                case .medication(let m): medications.append(m)
                case .condition(let c):  conditions.append(c)
                default: break
                }
            }
        }
        return IPSEmergencySubset(
            patientHash: hash,
            allergies: allergies,
            medications: medications,
            conditions: conditions,
            bloodGroup: nil,
            generatedAt: Date()
        )
    }

    private func encodeSubset(_ subset: IPSEmergencySubset) -> [String: Any] {
        // Encode a compact representation; the full payload is in the IPS bundle
        // fetched from the backend. QR carries just the critical emergency fields.
        [
            "ph": subset.patientHash,
            "al": subset.allergies.map { ["s": $0.snomedCode, "n": $0.substanceName, "sv": $0.severity.rawValue] },
            "mx": subset.medications.map { ["a": $0.atcCode, "n": $0.genericName] },
            "dx": subset.conditions.map { ["c": $0.icd10Code, "n": $0.displayName] },
        ]
    }
}

// MARK: - Data extension

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
