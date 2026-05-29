// IdentityVaultManager.swift — Silo 1: Identity + Personal data vault.
//
// KEY:   com.noborders.identity.key  (SE-bound, biometryCurrentSet)
// SEKEY: com.noborders.identity.sekey
// WRAPPEDKEY: com.noborders.identity.aes256-wrapped
//
// Contents: PatientIdentity, NationalIdentity, Diia/BankID/eIDAS verification
// records, UserProfile, SupportProfile, OperationalProfile, InsuranceRecords,
// EmergencyContacts, HealthcareProxy + Documents, ConsentRecords,
// SignatureRecords, DPA records.
//
// SECURITY INVARIANT:
//   • This vault MUST NOT contain any HealthRecord, Vitals, Medications,
//     Documents, LabResults, or any medical eHR data.
//     Medical data lives exclusively in MedicalVaultManager (Silo 2).
//   • РНОКПП / national ID numbers: SHA3-256 hash ONLY. Never plaintext.
//   • firstName/lastName: plaintext OK (needed for UI).
//   • NEVER send plaintext identity data to backend in JWT claims.
//
// Protocol-mandated SHA-256 exception:
//   SecKeyCreateEncryptedData/.eciesEncryptionCofactorVariableIVX963SHA256AESGCM
//   is required by Apple Security.framework. No SHA3 variant available.
//   (Accepted: security-gate-ios-sha2 exclusion rule applies.)

import Foundation
import CryptoKit
import Security

// MARK: - ProfileTypeStore
// Keychain-backed store for the user's ProfileType.
// Thread-safe; separate Keychain item from the vault AES key.

final class ProfileTypeStore: @unchecked Sendable {

    static let shared = ProfileTypeStore()

    private let keychainAccount = "com.noborders.profile.type"
    private let lock = NSLock()

    private init() {}

    func read() -> ProfileType {
        lock.lock(); defer { lock.unlock() }
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let raw  = String(data: data, encoding: .utf8),
              let type = ProfileType(rawValue: raw)
        else { return .civilian }
        return type
    }

    func write(_ type: ProfileType) {
        lock.lock(); defer { lock.unlock() }
        guard let data = type.rawValue.data(using: .utf8) else { return }
        let q: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    keychainAccount,
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - OperationalProfileStore
// Keychain-backed store for OperationalProfile (Silo 1: Identity Vault).

final class OperationalProfileStore: @unchecked Sendable {

    static let shared = OperationalProfileStore()

    private let keychainAccount = "com.noborders.operational.profile"
    private let lock = NSLock()

    private init() {}

    func read() -> OperationalProfile? {
        lock.lock(); defer { lock.unlock() }
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(OperationalProfile.self, from: data)
    }

    func write(_ profile: OperationalProfile) {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(profile) else { return }
        let q: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    keychainAccount,
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }

    func delete() {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete([
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
    }
}

// MARK: - IdentityKey

/// Keys for individual items within the Identity Vault (Silo 1).
/// Each key maps to a separate encrypted Keychain item.
enum IdentityKey: String {
    case patientIdentity     = "patient.identity"
    case nationalIdentity    = "national.identity"
    case diiaVerification    = "diia.verification"
    case bankidVerification  = "bankid.verification"
    case yesVerification     = "yes.verification"
    case cmdVerification     = "cmd.verification"
    case eidasAssertion      = "eidas.assertion"
    case userProfile         = "user.profile"
    case supportProfile      = "support.profile"
    case operationalProfile  = "operational.profile"
    case insuranceRecords    = "insurance.records"
    case emergencyContacts   = "emergency.contacts"
    case healthcareProxy     = "healthcare.proxy"
    case consentRecords      = "consent.records"
    case signatureRecords    = "signature.records"
}

// MARK: - IdentityVaultManager

/// Silo 1: AES-256-GCM encrypted Identity vault.
/// Key: SE-bound P-256, biometryCurrentSet ACL — every unwrap requires biometric auth.
/// Each IdentityKey occupies a separate Keychain item (granular per-item access).
actor IdentityVaultManager {

    static let shared = IdentityVaultManager()

    // ── Key material accounts ─────────────────────────────────────────────────
    private let seTag            = "com.noborders.identity.sekey"
    private let wrappedKeyAccount = "com.noborders.identity.aes256-wrapped"
    private let itemAccountPrefix = "com.noborders.identity.item."

    // Keychain access group — resolves AppIdentifierPrefix from Info.plist at runtime.
    // Must match entitlements: $(AppIdentifierPrefix)com.noborders.identity.key
    // On simulator the prefix is empty; items fall back to the app’s default group.
    // nil on simulator (no AppIdentifierPrefix) — SecItem calls omit kSecAttrAccessGroup.
    private let keychainGroup: String? = {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return prefix.isEmpty ? nil : "\(prefix)com.noborders.identity.key"
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
            case .notFound:              return "Identity vault item not found"
            case .invalidData:           return "Identity vault data is corrupted"
            }
        }
    }

    // MARK: - Generic API

    /// Encode, encrypt and store any Codable value under an IdentityKey.
    func seal<T: Codable>(_ value: T, for key: IdentityKey) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let plain   = try enc.encode(value)
        let sealed  = try encrypt(plain)
        let account = itemAccountPrefix + key.rawValue
        let attrs: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData   as String: sealed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(withGroup(attrs) as CFDictionary)
        let status = SecItemAdd(withGroup(attrs) as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainWrite(status) }
    }

    /// Decrypt and decode any Codable value stored under an IdentityKey.
    func open<T: Codable>(_ type: T.Type, for key: IdentityKey) throws -> T {
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

    /// Delete an item from the Identity Vault.
    func delete(key: IdentityKey) throws {
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
    // Deletes the wrapped AES key, rendering all Identity Vault items permanently inaccessible.

    func wipeWrappedKey() {
        SecItemDelete(withGroup([
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: wrappedKeyAccount,
        ]) as CFDictionary)
    }

    // MARK: - Typed convenience — Consent (LegalVaultManager API compatibility)

    func sealConsent(_ record: ConsentRecord) throws {
        var records = (try? open([ConsentRecord].self, for: .consentRecords)) ?? []
        records.removeAll { $0.id == record.id }
        records.append(record)
        try seal(records, for: .consentRecords)
    }

    func openAllConsents() throws -> [ConsentRecord] {
        (try? open([ConsentRecord].self, for: .consentRecords)) ?? []
    }

    func revokeConsentType(_ type: ConsentType, revokedAt: Date = Date()) throws {
        var records = try open([ConsentRecord].self, for: .consentRecords)
        guard let recordIdx = records.indices.reversed().first(where: { idx in
            records[idx].items.contains { $0.type == type && $0.granted }
        }) else { throw VaultError.notFound }
        guard let itemIdx = records[recordIdx].items.firstIndex(where: { $0.type == type }) else {
            throw VaultError.notFound
        }
        records[recordIdx].items[itemIdx].granted   = false
        records[recordIdx].items[itemIdx].revokedAt = revokedAt
        try seal(records, for: .consentRecords)
    }

    func updateConsentTxHash(id: UUID, txHash: String) throws {
        var records = try open([ConsentRecord].self, for: .consentRecords)
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw VaultError.notFound
        }
        records[idx].blockchainTxHash = txHash
        try seal(records, for: .consentRecords)
    }

    // MARK: - Typed convenience — Proxy

    func sealProxy(_ proxy: HealthcareProxy) throws {
        var proxies = (try? open([HealthcareProxy].self, for: .healthcareProxy)) ?? []
        proxies.removeAll { $0.id == proxy.id }
        proxies.append(proxy)
        try seal(proxies, for: .healthcareProxy)
    }

    func openAllProxies() throws -> [HealthcareProxy] {
        (try? open([HealthcareProxy].self, for: .healthcareProxy)) ?? []
    }

    func updateProxyTxHash(id: UUID, txHash: String) throws {
        var proxies = try open([HealthcareProxy].self, for: .healthcareProxy)
        guard let idx = proxies.firstIndex(where: { $0.id == id }) else {
            throw VaultError.notFound
        }
        proxies[idx].blockchainTxHash = txHash
        try seal(proxies, for: .healthcareProxy)
    }

    // MARK: - Typed convenience — ProxyDocument

    func sealProxyDocument(_ doc: ProxyDocument) throws {
        // ProxyDocuments are stored as part of the proxy list (keyed by proxyId).
        // We keep a flat list and filter by proxyId on read.
        var docs = (try? open([ProxyDocument].self, for: .healthcareProxy)) ?? []
        docs.removeAll { $0.id == doc.id }
        docs.append(doc)
        // Re-encode as a combined store: proxies + proxy-documents share the key
        // using a wrapper; for simplicity we use a dedicated sub-key.
        let subAccount = itemAccountPrefix + "proxy.documents"
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let plain = try? enc.encode(docs),
           let sealed = try? encrypt(plain) {
            let attrs: [String: Any] = [
                kSecClass       as String: kSecClassGenericPassword,
                kSecAttrAccount as String: subAccount,
                kSecValueData   as String: sealed,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            SecItemDelete(withGroup(attrs) as CFDictionary)
            SecItemAdd(withGroup(attrs) as CFDictionary, nil)
        }
    }

    func openProxyDocuments(for proxyId: UUID) throws -> [ProxyDocument] {
        let subAccount = itemAccountPrefix + "proxy.documents"
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: subAccount,
            kSecReturnData  as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(withGroup(query) as CFDictionary, &result) == errSecSuccess,
              let sealed = result as? Data,
              let plain  = try? decrypt(sealed)
        else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let all = (try? dec.decode([ProxyDocument].self, from: plain)) ?? []
        return all.filter { $0.proxyId == proxyId }
    }

    func updateProxyDocumentTxHash(id: UUID, txHash: String) throws {
        let subAccount = itemAccountPrefix + "proxy.documents"
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: subAccount,
            kSecReturnData  as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(withGroup(query) as CFDictionary, &result) == errSecSuccess,
              let sealed = result as? Data,
              let plain  = try? decrypt(sealed)
        else { throw VaultError.notFound }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var docs = (try? dec.decode([ProxyDocument].self, from: plain)) ?? []
        guard let idx = docs.firstIndex(where: { $0.id == id }) else {
            throw VaultError.notFound
        }
        docs[idx].blockchainTxHash = txHash
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let newPlain = try? enc.encode(docs),
              let newSealed = try? encrypt(newPlain) else { throw VaultError.cryptoFailed }
        let attrs: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: subAccount,
            kSecValueData   as String: newSealed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(withGroup(attrs) as CFDictionary)
        let status = SecItemAdd(withGroup(attrs) as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainWrite(status) }
    }

    func sealShareGrant(_ grant: ProxyDocumentShareGrant, docId: UUID) throws {
        let subAccount = itemAccountPrefix + "proxy.documents"
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: subAccount,
            kSecReturnData  as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(withGroup(query) as CFDictionary, &result) == errSecSuccess,
              let sealed = result as? Data,
              let plain  = try? decrypt(sealed)
        else { throw VaultError.notFound }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var docs = (try? dec.decode([ProxyDocument].self, from: plain)) ?? []
        guard let docIdx = docs.firstIndex(where: { $0.id == docId }) else {
            throw VaultError.notFound
        }
        docs[docIdx].shareGrants.removeAll { $0.id == grant.id }
        docs[docIdx].shareGrants.append(grant)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let newPlain = try? enc.encode(docs),
              let newSealed = try? encrypt(newPlain) else { throw VaultError.cryptoFailed }
        let attrs: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: subAccount,
            kSecValueData   as String: newSealed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(withGroup(attrs) as CFDictionary)
        let status = SecItemAdd(withGroup(attrs) as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainWrite(status) }
    }

    func markShareGrantAccessed(grantId: UUID, docId: UUID, txHash: String?) throws {
        let subAccount = itemAccountPrefix + "proxy.documents"
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: subAccount,
            kSecReturnData  as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(withGroup(query) as CFDictionary, &result) == errSecSuccess,
              let sealed = result as? Data,
              let plain  = try? decrypt(sealed)
        else { throw VaultError.notFound }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var docs = (try? dec.decode([ProxyDocument].self, from: plain)) ?? []
        guard let docIdx = docs.firstIndex(where: { $0.id == docId }),
              let grantIdx = docs[docIdx].shareGrants.firstIndex(where: { $0.id == grantId })
        else { throw VaultError.notFound }
        docs[docIdx].shareGrants[grantIdx].accessedAt = Date()
        if let tx = txHash {
            docs[docIdx].shareGrants[grantIdx].blockchainTxHash = tx
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let newPlain = try? enc.encode(docs),
              let newSealed = try? encrypt(newPlain) else { throw VaultError.cryptoFailed }
        let attrs: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: subAccount,
            kSecValueData   as String: newSealed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(withGroup(attrs) as CFDictionary)
        let status = SecItemAdd(withGroup(attrs) as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainWrite(status) }
    }

    // MARK: - Typed convenience — Signature

    func sealSignatureRecord(_ sig: SignatureRecord) throws {
        var sigs = (try? open([SignatureRecord].self, for: .signatureRecords)) ?? []
        sigs.removeAll { $0.id == sig.id }
        sigs.append(sig)
        try seal(sigs, for: .signatureRecords)
    }

    func openSignatureRecords() throws -> [SignatureRecord] {
        (try? open([SignatureRecord].self, for: .signatureRecords)) ?? []
    }

    func updateSignatureTxHash(id: UUID, txHash: String) throws {
        var sigs = try open([SignatureRecord].self, for: .signatureRecords)
        guard let idx = sigs.firstIndex(where: { $0.id == id }) else {
            throw VaultError.notFound
        }
        sigs[idx].blockchainTxHash = txHash
        try seal(sigs, for: .signatureRecords)
    }

    // MARK: - Typed convenience — DPA

    func sealDataProcessingAuth(_ auth: DataProcessingAuthorization) throws {
        try seal(auth, for: .consentRecords)   // stored alongside consent
    }

    func openDataProcessingAuth() throws -> DataProcessingAuthorization? {
        try? open(DataProcessingAuthorization.self, for: .consentRecords)
    }

    // MARK: - GDPR Art.15 export

    func exportLegalPackage() throws -> Data {
        let consents  = (try? open([ConsentRecord].self, for: .consentRecords)) ?? []
        let proxies   = (try? open([HealthcareProxy].self, for: .healthcareProxy)) ?? []
        let sigs      = (try? open([SignatureRecord].self, for: .signatureRecords)) ?? []
        let bundle: [String: Any] = [
            "consents":   consents.map { try? JSONEncoder().encode($0) }.compactMap { $0 },
            "proxies":    proxies.map  { try? JSONEncoder().encode($0) }.compactMap { $0 },
            "signatures": sigs.map    { try? JSONEncoder().encode($0) }.compactMap { $0 },
        ]
        return try JSONSerialization.data(
            withJSONObject: bundle,
            options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - AES-256-GCM primitives
    // ECIES wrapping is protocol-mandated by Apple Security.framework (SHA-256 accepted per CLAUDE.md).

    private func identityKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: wrappedKeyAccount,
            kSecReturnData  as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(withGroup(query) as CFDictionary, &result)

        if status == errSecItemNotFound { return try createIdentityKey() }
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

    private func createIdentityKey() throws -> SymmetricKey {
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
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: wrappedKeyAccount,
            kSecValueData   as String: wrapped as Data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(withGroup(attrs) as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainWrite(status) }
        return SymmetricKey(data: raw)
    }

    private func encrypt(_ plaintext: Data) throws -> Data {
        let key = try identityKey()
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
        let key   = try identityKey()
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
