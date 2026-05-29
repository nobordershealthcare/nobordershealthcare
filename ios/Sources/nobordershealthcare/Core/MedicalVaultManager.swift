// MedicalVaultManager.swift — Silo 2: Medical / eHR data vault.
//
// KEY:        com.noborders.medical.key  (SE-bound, biometryCurrentSet)
// SEKEY:      com.noborders.medical.sekey
// WRAPPEDKEY: com.noborders.medical.aes256-wrapped
//
// Contents: HealthRecords, Vitals, Medications, Allergies, Documents, IPS,
// LabResults, MilitaryMedical, ForensicIdentifiers, TranslationCache.
//
// SECURITY INVARIANT:
//   • This vault MUST NOT contain any identity, consent, signature, or legal
//     data. All legal/identity data lives exclusively in IdentityVaultManager
//     (Silo 1) under com.noborders.identity.key.
//   • National ID numbers: SHA3-256 hash ONLY. Never plaintext in this vault.
//   • Military / forensic identifiers: stored as opaque blobs, never logged.
//
// BACKWARD-COMPATIBILITY:
//   SealedVault struct and seal(_ plaintext:) / open(_ vault:) are kept for
//   existing call sites in HealthRecord.swift, DocumentStore.swift, and
//   EmergencyCardService.swift. New code should prefer seal<T>/open<T>.
//
// Protocol-mandated SHA-256 exception:
//   SecKeyCreateEncryptedData/.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
//   is required by Apple Security.framework. No SHA3 variant available.
//   (Accepted: security-gate-ios-sha2 exclusion rule applies.)

import Foundation
import CryptoKit
import Security

// MARK: - MedicalKey

/// Keys for every logical data category in the Medical Vault (Silo 2).
enum MedicalKey: String {
    case healthRecords        = "health.records"
    case vitals               = "vitals"
    case medications          = "medications"
    case allergies            = "allergies"
    case documents            = "documents"
    case ips                  = "ips"
    case labResults           = "lab.results"
    case militaryMedical      = "military.medical"
    case forensicIdentifiers  = "forensic.identifiers"
    case translationCache     = "translation.cache"
}

// MARK: - MedicalVaultManager

/// Silo 2: AES-256-GCM encrypted Medical / eHR vault.
/// Key: SE-bound P-256, biometryCurrentSet ACL — every unwrap requires biometric auth.
/// Each MedicalKey occupies a separate Keychain item (granular per-item access).
actor MedicalVaultManager {

    static let shared = MedicalVaultManager()

    // ── Key material accounts ─────────────────────────────────────────────────
    private let seTag              = "com.noborders.medical.sekey"
    private let wrappedKeyAccount  = "com.noborders.medical.aes256-wrapped"
    private let itemAccountPrefix  = "com.noborders.medical.item."

    // Keychain access group — resolves AppIdentifierPrefix from Info.plist at runtime.
    // Must match entitlements: $(AppIdentifierPrefix)com.noborders.medical.key
    // nil on simulator (no AppIdentifierPrefix) — SecItem calls omit kSecAttrAccessGroup.
    private let keychainGroup: String? = {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return prefix.isEmpty ? nil : "\(prefix)com.nobords.medical.key"
    }()

    // Adds kSecAttrAccessGroup only when running on a real device (group is non-nil).
    private func withGroup(_ d: [String: Any]) -> [String: Any] {
        guard let g = keychainGroup else { return d }
        var m = d; m[kSecAttrAccessGroup as String] = g; return m
    }

    // ── Error type ───────────────────────────────────────────────────────────
    enum VaultError: LocalizedError {
        case randomFailed
        case keychainRead(OSStatus)
        case keychainWrite(OSStatus)
        case cryptoFailed
        case notFound
        case invalidData

        var errorDescription: String? {
            switch self {
            case .randomFailed:          return "SecRandomCopyBytes failed"
            case .keychainRead(let s):
                if s == -34018 { return "Keychain read failed: missing entitlement (errSecMissingEntitlement -34018). Check keychain-access-groups in .entitlements." }
                return "Keychain read error: OSStatus \(s)"
            case .keychainWrite(let s):
                if s == -34018 { return "Keychain write failed: missing entitlement (errSecMissingEntitlement -34018). Check keychain-access-groups in .entitlements." }
                return "Keychain write error: OSStatus \(s)"
            case .cryptoFailed:          return "AES-GCM operation failed"
            case .notFound:              return "Medical vault item not found"
            case .invalidData:           return "Medical vault data is corrupted"
            }
        }
    }

    // MARK: - SealedVault (backward-compatibility with existing call sites)

    /// Raw sealed blob. Kept for DocumentStore / HealthRecord / EmergencyCardService
    /// which persist SealedVault as JSON in their own Keychain items.
    /// New code should use `seal<T>(_, for:)` / `open<T>(_, for:)` instead.
    struct SealedVault: Codable, Sendable {
        let nonce:      Data
        let ciphertext: Data
        let tag:        Data
        let keyVersion: Int
    }

    // MARK: - Low-level seal/open (backward-compatible API)

    /// Encrypt raw Data and return a Codable SealedVault.
    /// Used by DocumentStore, EmergencyCardService, EmergencyCardSetupView.
    func seal(_ plaintext: Data) throws -> SealedVault {
        let key = try medicalKey()
        var nonce = Data(count: 12)
        guard nonce.withUnsafeMutableBytes({
            SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!)
        }) == errSecSuccess else { throw VaultError.randomFailed }
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed   = try AES.GCM.seal(plaintext, using: key, nonce: aesNonce)
        return SealedVault(
            nonce:      Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag:        sealed.tag,
            keyVersion: 1
        )
    }

    /// Decrypt a SealedVault and return the plaintext Data.
    func open(_ vault: SealedVault) throws -> Data {
        let key   = try medicalKey()
        let nonce = try AES.GCM.Nonce(data: vault.nonce)
        let box   = try AES.GCM.SealedBox(nonce: nonce,
                                           ciphertext: vault.ciphertext,
                                           tag: vault.tag)
        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultError.cryptoFailed
        }
    }

    // MARK: - Generic Codable API (preferred for new code)

    /// Encode, encrypt and store any Codable value under a MedicalKey.
    func seal<T: Codable>(_ value: T, for key: MedicalKey) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let plain   = try enc.encode(value)
        let sealed  = try encrypt(plain)
        let account = itemAccountPrefix + key.rawValue
        let attrs: [String: Any] = [
            kSecClass          as String: kSecClassGenericPassword,
            kSecAttrAccount    as String: account,
            kSecValueData      as String: sealed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(withGroup(attrs) as CFDictionary)
        let status = SecItemAdd(withGroup(attrs) as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainWrite(status) }
    }

    /// Decrypt and decode any Codable value stored under a MedicalKey.
    func open<T: Codable>(_ type: T.Type, for key: MedicalKey) throws -> T {
        let account = itemAccountPrefix + key.rawValue
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData  as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(withGroup(query) as CFDictionary, &result)
        guard status == errSecSuccess, let sealed = result as? Data else {
            if status == errSecItemNotFound { throw VaultError.notFound }
            throw VaultError.keychainRead(status)
        }
        let plain = try decrypt(sealed)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let value = try? dec.decode(type, from: plain) else {
            throw VaultError.invalidData
        }
        return value
    }

    /// Delete an item from the Medical Vault.
    func delete(key: MedicalKey) throws {
        let account = itemAccountPrefix + key.rawValue
        let status = SecItemDelete(withGroup([
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychainWrite(status)
        }
    }

    // MARK: - Jailbreak wipe
    // Deletes the wrapped AES key, rendering all Medical Vault items permanently inaccessible.

    func wipeWrappedKey() {
        SecItemDelete(withGroup([
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: wrappedKeyAccount,
        ]) as CFDictionary)
    }

    // MARK: - AES-256-GCM primitives
    // ECIES wrapping is protocol-mandated by Apple Security.framework (SHA-256 accepted per CLAUDE.md).

    private func medicalKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: wrappedKeyAccount,
            kSecReturnData  as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(withGroup(query) as CFDictionary, &result)

        if status == errSecItemNotFound { return try createMedicalKey() }
        guard status == errSecSuccess, let wrapped = result as? Data else {
            throw VaultError.keychainRead(status)
        }
        let seKey = try SecureEnclaveKey.loadOrGenerateNamed(tag: seTag)
        var err: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(
            seKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            wrapped as CFData,
            &err
        ) else { throw VaultError.cryptoFailed }
        let raw = plain as Data
        defer {
            var m = raw
            m.withUnsafeMutableBytes { memset($0.baseAddress, 0, $0.count) }
        }
        return SymmetricKey(data: raw)
    }

    private func createMedicalKey() throws -> SymmetricKey {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes) == errSecSuccess else {
            throw VaultError.randomFailed
        }
        let raw = Data(keyBytes)
        keyBytes = [UInt8](repeating: 0, count: 32)

        let seKey  = try SecureEnclaveKey.loadOrGenerateNamed(tag: seTag)
        let pubKey = try SecureEnclaveKey.publicKey(from: seKey)
        var err: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(
            pubKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            raw as CFData,
            &err
        ) else { throw VaultError.cryptoFailed }

        let attrs: [String: Any] = [
            kSecClass          as String: kSecClassGenericPassword,
            kSecAttrAccount    as String: wrappedKeyAccount,
            kSecValueData      as String: wrapped as Data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(withGroup(attrs) as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainWrite(status) }
        return SymmetricKey(data: raw)
    }

    private func encrypt(_ plaintext: Data) throws -> Data {
        let key = try medicalKey()
        var nonce = Data(count: 12)
        guard nonce.withUnsafeMutableBytes({
            SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!)
        }) == errSecSuccess else { throw VaultError.randomFailed }
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed   = try AES.GCM.seal(plaintext, using: key, nonce: aesNonce)
        return nonce + sealed.ciphertext + sealed.tag
    }

    private func decrypt(_ blob: Data) throws -> Data {
        guard blob.count > 28 else { throw VaultError.invalidData }
        let key   = try medicalKey()
        let nonce = try AES.GCM.Nonce(data: blob.prefix(12))
        let body  = blob.dropFirst(12)
        let tag   = body.suffix(16)
        let ct    = body.dropLast(16)
        let box   = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultError.cryptoFailed
        }
    }
}
