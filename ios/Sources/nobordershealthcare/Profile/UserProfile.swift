// UserProfile.swift — Core account profile created during onboarding Step 2.
//
// Fields: nickname (unique), salutation, email, phone (E.164),
//         security question + answer hash, recovery password hash.
//
// Password: SHA3-256(per-user-salt + password). Salt in Keychain, never exported.
// Answer:   SHA3-256(answer.lowercased().trimmed()). Plaintext never stored.
//
// HIBP check (RegistrationView) uses CryptoKit.Insecure.SHA1 for k-anonymity
//   protocol compliance only — same exception class as PKCE/RFC 7636.
//   Password storage always uses SHA3-256. See setPassword().
//
// Storage: Keychain "com.noborders.user.profile"
//   Separate from Silo 1 (medical), Silo 2 (legal), SupportProfile (support contact).

import Foundation
import Security

// MARK: - UserProfile

struct UserProfile: Codable, Sendable {

    // ── Account identity ──────────────────────────────────────────────
    var nickname:   String   // unique platform handle; 3-32 chars
    var salutation: String   // how the app and support address this user

    // ── Contact ───────────────────────────────────────────────────────
    var email: String        // RFC 5322 validated; corporate-domain checked when applicable
    var phone: String        // E.164 international format (+380 63 …)

    // ── Security question ─────────────────────────────────────────────
    var securityQuestion:    String   // display text (preset or custom)
    var securityQuestionKey: String   // SecurityQuestion.rawValue

    // SHA3-256(answer.lowercased().trimmingCharacters(in: .whitespaces))
    var securityAnswerHash: String

    // SHA3-256(passwordSalt + password) — salt at com.noborders.user.password.salt
    var passwordHash: String

    // ── Timestamps ────────────────────────────────────────────────────
    var createdAt: Date
    var updatedAt: Date

    // MARK: - Errors

    enum ProfileError: LocalizedError {
        case passwordTooShort
        case emptyAnswer
        case saltGenerationFailed
        case keychainFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .passwordTooShort:      return "Password must be at least 12 characters"
            case .emptyAnswer:           return "Security answer must not be empty"
            case .saltGenerationFailed:  return "Failed to generate password salt — CSPRNG unavailable"
            case .keychainFailed(let s): return "Keychain write failed: OSStatus \(s)"
            }
        }
    }

    // MARK: - Mutations

    /// Hash password with SHA3-256(salt + password) and store digest.
    /// Caller MUST zero the plaintext String immediately after this call.
    mutating func setPassword(_ plaintext: String) throws {
        guard plaintext.count >= 12 else { throw ProfileError.passwordTooShort }
        let salt = try loadOrCreatePasswordSalt()
        let combined = Data((salt + plaintext).utf8)
        passwordHash = SHA3_256.hash(data: combined).description
        updatedAt = Date()
    }

    /// Hash security answer with SHA3-256 and store digest.
    /// Caller MUST zero the plaintext String immediately after this call.
    mutating func setAnswer(_ plaintext: String) throws {
        let normalized = plaintext.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { throw ProfileError.emptyAnswer }
        securityAnswerHash = SHA3_256.hash(data: Data(normalized.utf8)).description
        updatedAt = Date()
    }

    /// Verify recovery password for the app-unlock / account-recovery flow.
    func verifyPassword(_ plaintext: String) -> Bool {
        guard let salt = try? existingPasswordSalt() else { return false }
        let hash = SHA3_256.hash(data: Data((salt + plaintext).utf8)).description
        return hash == passwordHash
    }

    /// Verify security answer (case-insensitive, trimmed).
    func verifyAnswer(_ plaintext: String) -> Bool {
        guard !securityAnswerHash.isEmpty else { return false }
        let normalized = plaintext.lowercased().trimmingCharacters(in: .whitespaces)
        return SHA3_256.hash(data: Data(normalized.utf8)).description == securityAnswerHash
    }

    // MARK: - Salt management

    private static let saltAccount = "com.noborders.user.password.salt"

    private func loadOrCreatePasswordSalt() throws -> String {
        if let existing = try? existingPasswordSalt() { return existing }

        var saltBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &saltBytes) == errSecSuccess else {
            throw ProfileError.saltGenerationFailed
        }
        let salt = Data(saltBytes).base64EncodedString()

        let attrs: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    Self.saltAccount,
            kSecValueData as String:      Data(salt.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProfileError.keychainFailed(status) }
        return salt
    }

    private func existingPasswordSalt() throws -> String {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: Self.saltAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let salt = String(data: data, encoding: .utf8)
        else { throw ProfileError.keychainFailed(status) }
        return salt
    }
}

// MARK: - UserProfileStore

/// Keychain-backed persistence for UserProfile.
/// Account key: "com.noborders.user.profile" — not Silo 1 or Silo 2.
enum UserProfileStore {

    private static let account = "com.noborders.user.profile"

    static func save(_ profile: UserProfile) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(profile) else { return }
        let attrs: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(attrs as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load() -> UserProfile? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(UserProfile.self, from: data)
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
