// NationalIdentityRecord.swift — Legal-vault storage for verified national IDs.
//
// One record per country.  Stores the backend-provided SHA3-256 hash and a
// pre-masked display string — the raw national ID never reaches this model.
//
// Storage:
//   Keychain account: com.noborders.legal.national-ids
//   Silo 2 (Legal Vault) — separate from eHR vault (Silo 1).
//   Encoding: JSON array, ISO 8601 dates, kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
//
// Logging rules (enforced by callers — never log PII fields):
//   Log:    countryCode, providerID, verifiedAt
//   Never:  firstName, patronymic, lastName, idMasked, idHash

import Foundation
import Security

// MARK: - NationalIdentityRecord

struct NationalIdentityRecord: Codable, Sendable, Identifiable {

    // ── Identity ─────────────────────────────────────────────────────────────

    /// Stable identifier; preserved across re-verification upserts.
    var id: UUID = UUID()

    /// ISO 3166-1 alpha-2, e.g. "UA", "DE", "PT"
    var countryCode: String

    /// National ID type token:
    ///   "rnokpp"   — Ukraine РНОКПП (10 digits)
    ///   "steuer-id"— Germany Steueridentifikationsnummer (11 digits)
    ///   "nif"      — Portugal NIF (9 digits)
    ///   "pesel"    — Poland PESEL (11 digits)
    var idType: String

    /// Pre-masked display string from the backend, e.g. "••••••7890".
    /// Show as-is — no client-side transformation.
    /// NEVER stored in any log or metric.
    var idMasked: String

    /// SHA3-256 hex digest, pre-computed by the backend.
    /// The only national-ID-derived value stored in the vault.
    /// NEVER stored in any log or metric.
    var idHash: String

    // ── Name (display only — NEVER logged) ───────────────────────────────────

    var firstName: String

    /// Patronymic — present in UA / some other cultures; nil otherwise.
    var patronymic: String?

    var lastName: String

    // ── Provider ─────────────────────────────────────────────────────────────

    /// Provider token: "diia" | "npa" | "cmd" | "eidas"
    var providerID: String

    // ── Timestamps ───────────────────────────────────────────────────────────

    var verifiedAt: Date
}

// MARK: - NationalIdentityStore

/// Keychain-backed persistence for the national-identity record list.
/// One record per countryCode — upsert replaces on re-verification, keeping the original id.
///
/// Keychain account: com.noborders.legal.national-ids  (Legal Vault silo)
/// Thread-safety: callers serialise mutations through the main actor.
struct NationalIdentityStore {

    private static let account = "com.nobords.legal.national-ids"

    // MARK: Read

    func load() -> [NationalIdentityRecord] {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.account,
            kSecReturnData  as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return [] }

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([NationalIdentityRecord].self, from: data)) ?? []
    }

    func all() -> [NationalIdentityRecord] { load() }

    // MARK: Write

    private func save(_ records: [NationalIdentityRecord]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(records) else { return }

        let attrs: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.account,
            kSecValueData   as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(attrs as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    /// Adds or replaces the record for this countryCode.
    /// If a record with the same countryCode already exists, it is replaced
    /// in-place while preserving its original id.
    func upsert(_ record: NationalIdentityRecord) {
        var list = load()
        var incoming = record
        if let existing = list.first(where: { $0.countryCode == record.countryCode }) {
            incoming.id = existing.id   // preserve original id across re-verifications
            list.removeAll { $0.countryCode == record.countryCode }
        }
        list.append(incoming)
        save(list)
    }

    func remove(id: UUID) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
    }
}
