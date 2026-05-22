// LegalVaultManager.swift — Encrypted storage for legal documents.
//
// SILO 2: iOS Secure Enclave — Legal vault.
// SILO 1 (eHR vault) is managed by VaultManager.swift — SEPARATE actor, SEPARATE key.
//
// KEY SEPARATION INVARIANT:
//   eHR vault:   Keychain tag  "com.noborders.vault.key"   (VaultManager)
//   Legal vault: Keychain tag  "com.noborders.legal.key"   (THIS FILE)
//
// A compromise of one key MUST NOT expose the other silo. The two vaults use
// separate Secure Enclave key pairs; the wrapped AES-256 blobs live in distinct
// Keychain items. Never share, copy, or derive one key from the other.
//
// Domain types are defined in Models.swift — DO NOT redeclare them here.
//
// Contents of the legal vault (schema v2):
//   - ConsentRecord              — GDPR consent grants and per-item revocations
//   - HealthcareProxy            — delegated medical decision authority
//   - ProxyDocument              — official documents attached to proxies
//   - DataProcessingAuthorization — GDPR Art.28 DPA
//   - SignatureRecord            — AdES (Advanced Electronic Signature) local copies
//
// BLOCKCHAIN RULE:
//   SignatureRecord: stored HERE (Silo 2) and anchored on Fabric Channel 1.
//   NEVER written to VaultManager (eHR vault / Silo 1).

import Foundation
import CryptoKit
import Security

// MARK: - Vault store (root Codable persisted as one sealed AES-GCM blob)

private struct LegalVaultStore: Codable {
    var consentRecords: [ConsentRecord] = []
    var proxies: [HealthcareProxy] = []
    var proxyDocuments: [ProxyDocument] = []
    var dataProcessingAuth: DataProcessingAuthorization? = nil
    var signatureRecords: [SignatureRecord] = []
    var schemaVersion: Int = 2    // v2: Models.swift types replace inline definitions
}

// MARK: - LegalVaultManager

// actor — all mutations serialised; no concurrent writes to the AES key or Keychain.
actor LegalVaultManager {

    static let shared = LegalVaultManager()

    // ── Key separation ────────────────────────────────────────────────────────
    // DIFFERENT from VaultManager.wrappedKeyAccount ("com.noborders.vault.aes256-wrapped").
    // These two Keychain items MUST NEVER be merged, aliased, or share the same SE key pair.
    private let wrappedKeyAccount = "com.noborders.legal.aes256-wrapped"
    private let storeAccount      = "com.noborders.legal.store"

    enum LegalVaultError: LocalizedError {
        case randomFailed
        case keychainRead(OSStatus)
        case keychainWrite(OSStatus)
        case cryptoFailed
        case notFound
        case invalidData

        var errorDescription: String? {
            switch self {
            case .randomFailed:          return "SecRandomCopyBytes failed — CSPRNG unavailable"
            case .keychainRead(let s):   return "Keychain read error: \(s)"
            case .keychainWrite(let s):  return "Keychain write error: \(s)"
            case .cryptoFailed:          return "AES-GCM operation failed"
            case .notFound:              return "Legal vault record not found"
            case .invalidData:           return "Legal vault data is corrupted"
            }
        }
    }

    // MARK: - Public API — seal (write)

    func sealConsent(_ record: ConsentRecord) async throws {
        var store = try loadStore()
        store.consentRecords.removeAll { $0.id == record.id }
        store.consentRecords.append(record)
        try saveStore(store)
    }

    func sealProxy(_ proxy: HealthcareProxy) async throws {
        var store = try loadStore()
        store.proxies.removeAll { $0.id == proxy.id }
        store.proxies.append(proxy)
        try saveStore(store)
    }

    func sealDataProcessingAuth(_ auth: DataProcessingAuthorization) async throws {
        var store = try loadStore()
        store.dataProcessingAuth = auth
        try saveStore(store)
    }

    func sealSignatureRecord(_ sig: SignatureRecord) async throws {
        var store = try loadStore()
        store.signatureRecords.removeAll { $0.id == sig.id }
        store.signatureRecords.append(sig)
        try saveStore(store)
    }

    func sealProxyDocument(_ doc: ProxyDocument) async throws {
        var store = try loadStore()
        store.proxyDocuments.removeAll { $0.id == doc.id }
        store.proxyDocuments.append(doc)
        try saveStore(store)
    }

    // MARK: - Public API — open (read)

    func openAllConsents() async throws -> [ConsentRecord] {
        return try loadStore().consentRecords
    }

    func openAllProxies() async throws -> [HealthcareProxy] {
        return try loadStore().proxies
    }

    func openDataProcessingAuth() async throws -> DataProcessingAuthorization? {
        return try loadStore().dataProcessingAuth
    }

    func openSignatureRecords() async throws -> [SignatureRecord] {
        return try loadStore().signatureRecords
    }

    func openProxyDocuments(for proxyId: UUID) async throws -> [ProxyDocument] {
        return try loadStore().proxyDocuments.filter { $0.proxyId == proxyId }
    }

    // MARK: - Share grant

    func sealShareGrant(_ grant: ProxyDocumentShareGrant, docId: UUID) async throws {
        var store = try loadStore()
        guard let idx = store.proxyDocuments.firstIndex(where: { $0.id == docId }) else {
            throw LegalVaultError.notFound
        }
        store.proxyDocuments[idx].shareGrants.removeAll { $0.id == grant.id }
        store.proxyDocuments[idx].shareGrants.append(grant)
        try saveStore(store)
    }

    func markShareGrantAccessed(grantId: UUID, docId: UUID, txHash: String?) async throws {
        var store = try loadStore()
        guard let docIdx = store.proxyDocuments.firstIndex(where: { $0.id == docId }),
              let grantIdx = store.proxyDocuments[docIdx].shareGrants.firstIndex(where: { $0.id == grantId }) else {
            throw LegalVaultError.notFound
        }
        store.proxyDocuments[docIdx].shareGrants[grantIdx].accessedAt = Date()
        if let tx = txHash {
            store.proxyDocuments[docIdx].shareGrants[grantIdx].blockchainTxHash = tx
        }
        try saveStore(store)
    }

    // MARK: - Blockchain txHash updates (called after on-chain confirmation)

    func updateConsentTxHash(id: UUID, txHash: String) async throws {
        var store = try loadStore()
        guard let idx = store.consentRecords.firstIndex(where: { $0.id == id }) else {
            throw LegalVaultError.notFound
        }
        store.consentRecords[idx].blockchainTxHash = txHash
        try saveStore(store)
    }

    func updateSignatureTxHash(id: UUID, txHash: String) async throws {
        var store = try loadStore()
        guard let idx = store.signatureRecords.firstIndex(where: { $0.id == id }) else {
            throw LegalVaultError.notFound
        }
        store.signatureRecords[idx].blockchainTxHash = txHash
        try saveStore(store)
    }

    func updateProxyTxHash(id: UUID, txHash: String) async throws {
        var store = try loadStore()
        guard let idx = store.proxies.firstIndex(where: { $0.id == id }) else {
            throw LegalVaultError.notFound
        }
        store.proxies[idx].blockchainTxHash = txHash
        try saveStore(store)
    }

    func updateProxyDocumentTxHash(id: UUID, txHash: String) async throws {
        var store = try loadStore()
        guard let idx = store.proxyDocuments.firstIndex(where: { $0.id == id }) else {
            throw LegalVaultError.notFound
        }
        store.proxyDocuments[idx].blockchainTxHash = txHash
        try saveStore(store)
    }

    // MARK: - Consent revocation (GDPR Art.7(3) — immediate, per-item)

    /// Revokes a specific ConsentType within the most recent matching ConsentRecord.
    /// Sets granted = false and records the revocation timestamp.
    func revokeConsentType(_ type: ConsentType, revokedAt: Date = Date()) async throws {
        var store = try loadStore()
        // Most-recent record that has a granted item of this type
        guard let recordIdx = store.consentRecords.indices.reversed().first(where: { idx in
            store.consentRecords[idx].items.contains { $0.type == type && $0.granted }
        }) else {
            throw LegalVaultError.notFound
        }
        guard let itemIdx = store.consentRecords[recordIdx].items.firstIndex(where: { $0.type == type }) else {
            throw LegalVaultError.notFound
        }
        store.consentRecords[recordIdx].items[itemIdx].granted = false
        store.consentRecords[recordIdx].items[itemIdx].revokedAt = revokedAt
        try saveStore(store)
    }

    // MARK: - GDPR Art.15 export

    /// Returns a JSON blob containing all legal records for patient data portability.
    func exportLegalPackage() async throws -> Data {
        let store = try loadStore()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(store)
    }

    // MARK: - AES-256-GCM store encryption
    // Uses the legal vault key — NEVER the eHR vault key from VaultManager.

    private func loadStore() throws -> LegalVaultStore {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: storeAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return LegalVaultStore() // first use — empty store
        }
        guard status == errSecSuccess, let sealed = result as? Data else {
            throw LegalVaultError.keychainRead(status)
        }
        let plain = try decrypt(sealed)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let store = try? decoder.decode(LegalVaultStore.self, from: plain) else {
            throw LegalVaultError.invalidData
        }
        return store
    }

    private func saveStore(_ store: LegalVaultStore) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(store)
        let sealed = try encrypt(plain)

        let attrs: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    storeAccount,
            kSecValueData as String:      sealed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(attrs as CFDictionary)
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LegalVaultError.keychainWrite(status)
        }
    }

    // MARK: - Key management (legal vault key — SEPARATE from eHR key)

    private func legalKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: wrappedKeyAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return try createLegalKey()
        }
        guard status == errSecSuccess, let wrapped = result as? Data else {
            throw LegalVaultError.keychainRead(status)
        }
        // Unwrap using the LEGAL vault SE key — never the eHR SE key.
        let seKey = try SecureEnclaveKey.loadNamed(tag: "com.noborders.legal.sekey")
        var decryptError: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(
            seKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            wrapped as CFData,
            &decryptError
        ) else {
            throw LegalVaultError.cryptoFailed
        }
        let rawKey = decrypted as Data
        defer {
            var mutableKey = rawKey
            mutableKey.withUnsafeMutableBytes { memset($0.baseAddress, 0, $0.count) }
        }
        return SymmetricKey(data: rawKey)
    }

    private func createLegalKey() throws -> SymmetricKey {
        var keyBytes = [UInt8](repeating: 0, count: 32) // 256 bits
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes) == errSecSuccess else {
            throw LegalVaultError.randomFailed
        }
        let rawKey = Data(keyBytes)
        keyBytes = [UInt8](repeating: 0, count: 32) // zero immediately

        let seKey = try SecureEnclaveKey.loadNamed(tag: "com.noborders.legal.sekey")
        let pubKey = try SecureEnclaveKey.publicKey(from: seKey)
        var encryptError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            pubKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            rawKey as CFData,
            &encryptError
        ) else {
            throw LegalVaultError.cryptoFailed
        }
        let wrapped = encrypted as Data

        let attrs: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    wrappedKeyAccount,
            kSecValueData as String:      wrapped,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LegalVaultError.keychainWrite(status)
        }
        return SymmetricKey(data: rawKey)
    }

    // MARK: - AES-256-GCM primitives

    private func encrypt(_ plaintext: Data) throws -> Data {
        let key = try legalKey()
        var nonce = Data(count: 12)
        guard nonce.withUnsafeMutableBytes({
            SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!)
        }) == errSecSuccess else {
            throw LegalVaultError.randomFailed
        }
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed   = try AES.GCM.seal(plaintext, using: key, nonce: aesNonce)
        // Layout: nonce(12) || ciphertext || tag(16)
        return nonce + sealed.ciphertext + sealed.tag
    }

    private func decrypt(_ blob: Data) throws -> Data {
        guard blob.count > 28 else { throw LegalVaultError.invalidData } // 12 + 0 + 16
        let key   = try legalKey()
        let nonce = try AES.GCM.Nonce(data: blob.prefix(12))
        let body  = blob.dropFirst(12)
        let tag   = body.suffix(16)
        let ct    = body.dropLast(16)
        let box   = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            throw LegalVaultError.cryptoFailed
        }
    }
}
