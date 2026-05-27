// EmergencyCardService.swift — Phase 4: single source of truth for the live emergency JWT.
//
// @MainActor ObservableObject — QRGeneratorView binds to @Published tokenState.
// Reads EmergencyCard from Silo 1 (VaultManager, vault/emergency-card.enc).
// JWT signed Ed25519 via KeyManager — biometric gate is enforced by the SE key ACL.
// Token (raw JWT string) cached in App Group keychain so EmergencyWidget can read it.
// Countdown runs as a cooperative Task, updating @Published tokenState every second.
// On revoke: new jti issued, old jti background-POSTed to /auth/revoke on the Gatekeeper.
//
// SILO BOUNDARY: reads from Silo 1 only (VaultManager / com.noborders.vault.key).
//               Does NOT touch LegalVaultManager or com.noborders.legal.key.
// LOGGING:      Only SHA3-256(userIdHash) in logs — never displayName, DOB, or any PII.
// MEDICATIONS:  ATC codes carried through from EmergencyCard.medications.atcCode — NEVER RxNorm.

import Foundation
import Security

// MARK: - TokenState

/// Live state of the emergency JWT.
/// The JWT string is embedded in the associated value so QRGeneratorView never needs to
/// decode the keychain separately — it just observes `tokenState`.
enum TokenState: Sendable, Equatable {
    case valid(jwt: String, expiresIn: TimeInterval)   // > 120 s remaining
    case expiring(jwt: String, secondsLeft: Int)        // ≤ 120 s remaining
    case expired                                        // past exp claim
    case missing                                        // never issued or cleared
}

// MARK: - EmergencyCardService

@MainActor
final class EmergencyCardService: ObservableObject {

    static let shared = EmergencyCardService()

    /// Observed by QRGeneratorView via @ObservedObject / @StateObject.
    @Published private(set) var tokenState: TokenState = .missing

    /// AsyncStream mirror of tokenState for non-SwiftUI consumers (widget, watch companion).
    let tokenStream: AsyncStream<TokenState>
    private let streamContinuation: AsyncStream<TokenState>.Continuation

    private let appGroupID        = "group.com.noborders.emergency"
    private let tokenKeychainKey  = "com.noborders.jwt.emergency"
    private var countdownTask: Task<Void, Never>?

    // MARK: - Errors

    enum ServiceError: Error, LocalizedError {
        case noEmergencyCard
        case signingFailed(Error)
        case keychainFailed(OSStatus)
        case jsonSerializationFailed

        var errorDescription: String? {
            switch self {
            case .noEmergencyCard:         return "No emergency card found — complete setup first"
            case .signingFailed(let e):    return "JWT signing failed: \(e.localizedDescription)"
            case .keychainFailed(let s):   return "Keychain error: OSStatus \(s)"
            case .jsonSerializationFailed: return "JWT payload serialization failed"
            }
        }
    }

    // MARK: - Init

    private init() {
        let (stream, cont) = AsyncStream.makeStream(of: TokenState.self)
        tokenStream = stream
        streamContinuation = cont
    }

    // MARK: - Public API

    /// Call on app foreground and when QRGeneratorView appears.
    /// Loads cached JWT from App Group keychain if still valid; otherwise issues a new token.
    /// Reading the JWT from keychain does NOT trigger biometrics.
    /// Signing a new JWT triggers biometrics via the Secure Enclave key ACL.
    func refreshIfNeeded() async {
        switch tokenState {
        case .valid, .expiring:
            return  // already running countdown — nothing to do
        case .expired, .missing:
            break
        }
        // Try reading cached JWT without biometric prompt
        if let (jwt, expiry) = loadStoredJWT(), expiry > Date() {
            applyState(jwt: jwt, expiry: expiry)
            startCountdown(jwt: jwt, expiresAt: expiry)
            return
        }
        await issueNewToken()
    }

    /// Biometric-gated manual refresh (user taps "Refresh" in QRGeneratorView).
    func forceRefresh() async throws {
        try await BiometricAuth.shared.evaluate(
            reason: "Authenticate to refresh your emergency QR code"
        )
        await issueNewToken()
    }

    /// Revoke current token, issue replacement, background-blacklist old jti.
    /// Returns the old jti string (may be empty if no prior token existed).
    @discardableResult
    func revoke() async throws -> String {
        let oldJTI = extractJTI(from: loadStoredJWT()?.jwt)
        clearStoredToken()
        tokenState = .missing
        streamContinuation.yield(.missing)
        try await BiometricAuth.shared.evaluate(
            reason: "Authenticate to revoke and re-issue your emergency QR"
        )
        await issueNewToken()
        if let jti = oldJTI {
            Task.detached(priority: .utility) {
                await self.reportRevocation(jti: jti)
            }
        }
        return oldJTI ?? ""
    }

    // MARK: - JWT issuance

    private func issueNewToken() async {
        do {
            let card  = try await loadEmergencyCard()
            let jwt   = try await buildJWT(from: card)
            let expiry = expiry(from: jwt) ?? Date().addingTimeInterval(900)
            try storeJWT(jwt)
            applyState(jwt: jwt, expiry: expiry)
            startCountdown(jwt: jwt, expiresAt: expiry)
        } catch {
            tokenState = .missing
            streamContinuation.yield(.missing)
        }
    }

    /// Builds a signed EdDSA JWT from the patient's EmergencyCard.
    /// Payload claims (spec-mandated):
    ///   sub, name, dob, blood, allergies, medications, lang, pk, iat, exp, jti
    /// Medications carry ATC code where available — never RxNorm.
    func buildJWT(from card: EmergencyCard) async throws -> String {
        let userIdHash = try await DIDWallet.shared.currentUserIdHash()
        let pubKeyData = try await KeyManager.shared.ed25519PublicKeyData()
        let pubKeyB64  = pubKeyData.base64URLEncodedString()
        let lang       = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        let jti        = UUID().uuidString.lowercased()
        let now        = Date()
        let exp        = now.addingTimeInterval(900)   // 15-minute TTL

        let dobFmt = ISO8601DateFormatter()
        dobFmt.formatOptions = [.withFullDate]

        let medsArray: [[String: String]] = card.medications.map { med in
            var m: [String: String] = [
                "name": med.name,
                "dose": med.dose,
                "freq": med.frequency,
            ]
            if let atc = med.atcCode { m["atc"] = atc }   // ATC only — NEVER RxNorm
            return m
        }

        let profileType = ProfileTypeStore.shared.read().rawValue
        let opProfile = OperationalProfileStore.shared.read()
        let identityProtection = opProfile?.identityProtection.rawValue ?? IdentityProtectionLevel.standard.rawValue
        let emergencyScope = opProfile?.emergencyCardScope ?? ["name", "dob", "blood_type", "allergies", "medications", "nok_direct"]

        let payloadDict: [String: Any] = [
            "sub":                userIdHash,
            "name":               card.displayName,
            "dob":                dobFmt.string(from: card.dateOfBirth),
            "blood":              card.bloodType.rawValue,
            "allergies":          card.allergies,
            "medications":        medsArray,
            "lang":               lang,
            "pk":                 pubKeyB64,
            "profile_type":       profileType,
            "identity_protection": identityProtection,
            "scope":              emergencyScope,
            "iat":                Int(now.timeIntervalSince1970),
            "exp":                Int(exp.timeIntervalSince1970),
            "jti":                jti,
        ]

        let header  = try base64url(json: ["alg": "EdDSA", "typ": "JWT"])
        let payload = try base64url(json: payloadDict)

        let signingInput = Data("\(header).\(payload)".utf8)
        let signature: Data
        do {
            signature = try await KeyManager.shared.sign(signingInput)
        } catch {
            throw ServiceError.signingFailed(error)
        }

        return "\(header).\(payload).\(signature.base64URLEncodedString())"
    }

    // MARK: - EmergencyCard loading (Silo 1 — eHR vault)

    private func loadEmergencyCard() async throws -> EmergencyCard {
        let vaultDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vault", isDirectory: true)
        let fileURL = vaultDir.appendingPathComponent("emergency-card.enc")

        guard let sealedData = try? Data(contentsOf: fileURL) else {
            throw ServiceError.noEmergencyCard
        }
        let sealed = try JSONDecoder().decode(VaultManager.SealedVault.self, from: sealedData)
        let plaintext = try await VaultManager.shared.open(sealed)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(EmergencyCard.self, from: plaintext)
    }

    // MARK: - Countdown

    private func applyState(jwt: String, expiry: Date) {
        let remaining = expiry.timeIntervalSinceNow
        let state: TokenState
        if remaining > 120 {
            state = .valid(jwt: jwt, expiresIn: remaining)
        } else if remaining > 0 {
            state = .expiring(jwt: jwt, secondsLeft: Int(remaining))
        } else {
            state = .expired
        }
        tokenState = state
        streamContinuation.yield(state)
    }

    private func startCountdown(jwt: String, expiresAt expiry: Date) {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                guard !Task.isCancelled else { break }
                let remaining = expiry.timeIntervalSinceNow
                let state: TokenState
                if remaining > 120 {
                    state = .valid(jwt: jwt, expiresIn: remaining)
                } else if remaining > 0 {
                    state = .expiring(jwt: jwt, secondsLeft: Int(remaining))
                } else {
                    state = .expired
                    await MainActor.run {
                        self.tokenState = state
                        self.streamContinuation.yield(state)
                    }
                    break
                }
                await MainActor.run {
                    self.tokenState = state
                    self.streamContinuation.yield(state)
                }
            }
        }
    }

    // MARK: - App Group Keychain

    private func storeJWT(_ jwt: String) throws {
        guard let data = jwt.data(using: .utf8) else { return }
        let q: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      tokenKeychainKey,
            kSecAttrAccessGroup as String:  appGroupID,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw ServiceError.keychainFailed(status) }
    }

    private func loadStoredJWT() -> (jwt: String, expiry: Date)? {
        let q: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      tokenKeychainKey,
            kSecAttrAccessGroup as String:  appGroupID,
            kSecReturnData as String:       true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let jwt = String(data: data, encoding: .utf8),
              let exp = expiry(from: jwt),
              exp > Date()
        else { return nil }
        return (jwt, exp)
    }

    private func clearStoredToken() {
        let q: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      tokenKeychainKey,
            kSecAttrAccessGroup as String:  appGroupID,
        ]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - JWT helpers

    private func base64url(json: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            throw ServiceError.jsonSerializationFailed
        }
        return data.base64URLEncodedString()
    }

    private func expiry(from jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let exp = json["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func extractJTI(from jwt: String?) -> String? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let jti = json["jti"] as? String
        else { return nil }
        return jti
    }

    // MARK: - Revocation

    private func reportRevocation(jti: String) async {
        let url = AppConfig.authRevokeURL
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["jti": jti])
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Data + base64url (file-private — avoids redeclaration with other files)

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        self.init(base64Encoded: s)
    }
}
