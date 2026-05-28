// VerifiedIdentity.swift — Multi-country verified identity model.
//
// A user may hold any number of verified identities, one per (country, provider)
// pair.  Each record stores only the SHA3-256 hash of the national ID — the
// plaintext is zeroed from memory immediately after hashing in IdentityView.
//
// Keychain account: "com.noborders.identity.verified.list"
//   Separate from eHR vault (Silo 1), Legal vault (Silo 2), UserProfile.

import Foundation
import Security

// MARK: - VerifiedIdentity

struct VerifiedIdentity: Codable, Sendable, Identifiable {

    var id: UUID             = UUID()

    // ── Country ─────────────────────────────────────────────────────────────
    var countryCode: String   // ISO 3166-1 alpha-2, e.g. "PT", "UA", "DE", "SA"
    var countryFlag: String   // flag emoji, e.g. "🇵🇹"
    var countryName: String   // display name, e.g. "Portugal"

    // ── Provider ────────────────────────────────────────────────────────────
    var providerID: String    // e.g. "cmd-pt", "diia-ua", "npa-de", "eidas"
    var providerName: String  // e.g. "CMD – Chave Móvel Digital"

    // ── Hash (GDPR Art.9 — NO plaintext ever stored) ─────────────────────
    // SHA3_256(per-user-salt + normalizedNationalID)
    var userIdHash: String

    // ── Timestamps ──────────────────────────────────────────────────────────
    var verifiedAt: Date
    var expiresAt: Date?      // nil = no expiry; set for re-verification requirements
}

// MARK: - VerifiedIdentityStore

/// Keychain-backed persistence for the full list of verified identities.
/// Supports N identities — one per (countryCode, providerID) pair.
///
/// Thread-safety: all mutations are serialised through the main actor in
/// callers; the Keychain calls themselves are synchronous and atomic.
enum VerifiedIdentityStore {

    private static let account = "com.noborders.identity.verified.list"

    // MARK: Read

    static func loadAll() -> [VerifiedIdentity] {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return [] }

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([VerifiedIdentity].self, from: data)) ?? []
    }

    static func hasAny() -> Bool { !loadAll().isEmpty }

    // MARK: Write

    static func saveAll(_ identities: [VerifiedIdentity]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(identities) else { return }

        let attrs: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(attrs as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    /// Adds or replaces an identity.  If a record with the same
    /// (countryCode, providerID) already exists it is updated in-place.
    static func upsert(_ identity: VerifiedIdentity) {
        var list = loadAll()
        list.removeAll { $0.countryCode == identity.countryCode
                      && $0.providerID  == identity.providerID }
        list.append(identity)
        // Primary country (first linked) stays at index 0
        saveAll(list)
    }

    static func remove(id: UUID) {
        var list = loadAll()
        list.removeAll { $0.id == id }
        saveAll(list)
    }

    static func deleteAll() {
        SecItemDelete([
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
