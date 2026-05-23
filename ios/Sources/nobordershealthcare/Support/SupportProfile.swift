// SupportProfile.swift — Support identity profile for inbound contact verification.
//
// Bank-model 3-factor verification for support agents:
//   Factor 1: nickname    — patient-chosen short name; support greets them by salutation
//   Factor 2: dateOfBirth — read from live EmergencyCard (Silo 1), never duplicated here
//   Factor 3: security question + hashed answer
//
// securityAnswerHash: SHA256(answer.lowercased().trimmingCharacters(in: .whitespaces))
//   CryptoKit SHA256 — support identification data only.
//   Medical/legal data uses SHA3-256 (backend Go services).
// The plaintext answer is NEVER stored anywhere.
//
// Storage: Keychain item "com.noborders.support.profile"
//   Not Silo 1 (medical) or Silo 2 (legal) — it is contact/identity metadata.
//   Uses kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
//
// SECURITY NOTE: callers of verify() MUST show users a generic "verification
// failed" message — never which factor failed.  The typed VerificationError
// values are for internal logs (log SHA256(supportAgentID) only, never PII).

import Foundation
import Security
import CryptoKit

// MARK: - SecurityQuestion

enum SecurityQuestion: String, Codable, CaseIterable, Sendable {
    case firstPet          = "firstPet"
    case mothersMaidenName = "mothersMaidenName"
    case birthCity         = "birthCity"
    case firstSchool       = "firstSchool"
    case childhoodNickname = "childhoodNickname"
    case favoriteTeacher   = "favoriteTeacher"
    case customQuestion    = "customQuestion"

    var displayLabel: String {
        switch self {
        case .firstPet:          return "Name of your first pet?"
        case .mothersMaidenName: return "Your mother's maiden name?"
        case .birthCity:         return "City you were born in?"
        case .firstSchool:       return "Name of your first school?"
        case .childhoodNickname: return "Your childhood nickname?"
        case .favoriteTeacher:   return "Your favourite teacher's surname?"
        case .customQuestion:    return "Custom question…"
        }
    }
}

// MARK: - SupportProfile

struct SupportProfile: Codable, Sendable {
    // How support addresses the user in chat (patient-chosen, any locale or title)
    var salutation: String        // "Марія Миколаївна" / "Mr. Smith" / "Ваше Величносте"

    // Short name shown in support chat headers
    var nickname: String

    // The question text shown to the patient during support verification
    // For preset questions: SecurityQuestion.displayLabel
    // For custom:           the patient's own question text
    var securityQuestion: String

    // SecurityQuestion.rawValue — used to restore picker state in the UI
    // nil if the question has not been set yet
    var securityQuestionKey: String?

    // SHA3-256(answer.lowercased().trimmingCharacters(in: .whitespaces))
    // "" when no answer has been set yet
    var securityAnswerHash: String

    var updatedAt: Date

    // MARK: - Setup

    enum SetupError: LocalizedError {
        case emptyAnswer
        case emptyNickname

        var errorDescription: String? {
            switch self {
            case .emptyAnswer:   return "Security answer must not be empty"
            case .emptyNickname: return "Nickname must not be empty"
            }
        }
    }

    /// Hash `plaintext` with SHA3-256 and store the digest.
    /// The plaintext is never written to any persistent field.
    /// Callers MUST zero their plaintext @State var immediately after calling this.
    mutating func setAnswer(_ plaintext: String) throws {
        let normalized = plaintext.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { throw SetupError.emptyAnswer }
        securityAnswerHash = SHA256.hash(data: Data(normalized.utf8))
                .map { String(format: "%02x", $0) }.joined()
        updatedAt = Date()
    }

    // MARK: - Single-factor answer check (used by ChangeSecurityQuestionSheet)

    /// Returns true when SHA3-256(normalized plaintext) matches the stored hash.
    /// Used to gate the "change security question" flow (verify old answer first).
    func verifyAnswer(_ plaintext: String) -> Bool {
        guard !securityAnswerHash.isEmpty else { return false }
        let normalized = plaintext.lowercased().trimmingCharacters(in: .whitespaces)
        let candidate  = SHA256.hash(data: Data(normalized.utf8))
                .map { String(format: "%02x", $0) }.joined()
        return candidate == securityAnswerHash
    }

    // MARK: - Full 3-factor verification

    enum VerificationError: LocalizedError {
        case nicknameMismatch
        case dobMismatch
        case answerMismatch

        var errorDescription: String? {
            switch self {
            case .nicknameMismatch: return "Nickname does not match"
            case .dobMismatch:      return "Date of birth does not match"
            case .answerMismatch:   return "Security answer is incorrect"
            }
        }
    }

    /// Verify all 3 factors for support identity confirmation.
    ///
    /// `cardDOB` must come from the live EmergencyCard loaded from Silo 1.
    /// It is NOT stored here to avoid silo boundary violations.
    ///
    /// SECURITY: callers MUST NOT expose which factor failed to the end user.
    func verify(
        candidateNickname: String,
        candidateDOB: Date,
        cardDOB: Date,
        candidateAnswer: String
    ) throws {
        // Factor 1: nickname (case-insensitive, trimmed)
        guard candidateNickname.lowercased().trimmingCharacters(in: .whitespaces)
                == nickname.lowercased().trimmingCharacters(in: .whitespaces)
        else { throw VerificationError.nicknameMismatch }

        // Factor 2: date of birth — calendar-day precision only (ignores time component)
        guard Calendar.current.isDate(candidateDOB, inSameDayAs: cardDOB)
        else { throw VerificationError.dobMismatch }

        // Factor 3: security answer — compare SHA3-256 digests
        let normalized = candidateAnswer.lowercased().trimmingCharacters(in: .whitespaces)
        let hash = SHA256.hash(data: Data(normalized.utf8))
                .map { String(format: "%02x", $0) }.joined()
        guard hash == securityAnswerHash
        else { throw VerificationError.answerMismatch }
    }
}

// MARK: - SupportProfileStore

/// Keychain persistence for SupportProfile.
/// Item stored at account key "com.noborders.support.profile".
/// Not part of Silo 1 (eHR vault) or Silo 2 (legal vault).
enum SupportProfileStore {

    private static let account = "com.noborders.support.profile"

    static func save(_ profile: SupportProfile) {
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

    static func load() -> SupportProfile? {
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
        return try? dec.decode(SupportProfile.self, from: data)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
