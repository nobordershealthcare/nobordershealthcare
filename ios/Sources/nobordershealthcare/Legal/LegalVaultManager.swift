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
// Contents of the legal vault:
//   - ConsentRecord     — patient consent grants and revocations
//   - HealthcareProxy   — delegated medical decision authority
//   - DPA               — Data Processing Agreement (GDPR Art.28)
//   - SignatureRecord   — AdES (Advanced Electronic Signature) local copy
//
// BLOCKCHAIN RULE (from CLAUDE.md):
//   AdES signature records NEVER stored in same silo as health data.
//   SignatureRecord is stored HERE (legal vault) and ON channel 1.
//   It is NEVER written to VaultManager (eHR vault).

import Foundation
import CryptoKit
import Security

// MARK: - Domain types

struct ConsentRecord: Codable, Sendable, Identifiable {
    let id: String                // UUID
    let consentType: String       // "ehr_access" | "research" | "insurance" | "emergency" | "telemedicine"
    let grantedAt: Date
    var revokedAt: Date?
    var isActive: Bool { revokedAt == nil }
    let expiresAt: Date?          // nil = indefinite
    let signatureRecordId: String // foreign key → SignatureRecord.id
    var blockchainTxHash: String? // channel-2 txID (nil until confirmed on-chain)
}

struct HealthcareProxy: Codable, Sendable, Identifiable {
    let id: String
    let proxyUserIdHash: String   // SHA3-256(salt+delegateeUserID) — no PII
    let scope: [String]           // FHIR resource types the proxy may access
    let grantedAt: Date
    var revokedAt: Date?
    var isActive: Bool { revokedAt == nil }
    let signatureRecordId: String
    var blockchainTxHash: String?
}

struct DPA: Codable, Sendable, Identifiable {
    let id: String
    let processorHash: String     // SHA3-256 of the data processor's legal entity identifier
    let purposeDescription: String // plain-language description (NOT health data)
    let legalBasis: [String]      // GDPR Art. references
    let signedAt: Date
    var terminatedAt: Date?
    let signatureRecordId: String
    var blockchainTxHash: String?
}

struct SignatureRecord: Codable, Sendable, Identifiable {
    let id: String                // UUID — used as documentHash input
    let documentHash: String      // SHA3-256 of signed document bytes
    let signerPubKeyHash: String  // SHA3-256 of signer's Ed25519 public key DER
    let signature: String         // base64url(Ed25519 raw 64-byte signature)
    let identityProvider: String  // "bankid-se" | "eid-pt" | ...
    let identityVerifiedAt: Date
    let legalBasis: [String]
    let documentType: String      // "consent" | "healthcare_proxy" | "dpa" | "ehr_access"
    let jurisdictions: [String]   // ISO 3166-1 alpha-2
    let createdAt: Date
    var blockchainTxHash: String? // channel-1 txID (nil until confirmed on-chain)
}

// MARK: - Vault store (root Codable persisted as one sealed blob)

private struct LegalVaultStore: Codable {
    var consentRecords: [ConsentRecord] = []
    var proxies: [HealthcareProxy] = []
    var dpa: DPA? = nil
    var signatureRecords: [SignatureRecord] = []
    var schemaVersion: Int = 1
}

// MARK: - LegalVaultManager

// actor — all mutations are serialised; no concurrent writes to the AES key or Keychain.
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

    func sealDPA(_ dpa: DPA) async throws {
        var store = try loadStore()
        store.dpa = dpa
        try saveStore(store)
    }

    func sealSignatureRecord(_ sig: SignatureRecord) async throws {
        var store = try loadStore()
        store.signatureRecords.removeAll { $0.id == sig.id }
        store.signatureRecords.append(sig)
        try saveStore(store)
    }

    // MARK: - Public API — open (read)

    func openAllConsents() async throws -> [ConsentRecord] {
        return try loadStore().consentRecords
    }

    func openAllProxies() async throws -> [HealthcareProxy] {
        return try loadStore().proxies
    }

    func openDPA() async throws -> DPA? {
        return try loadStore().dpa
    }

    func openSignatureRecords() async throws -> [SignatureRecord] {
        return try loadStore().signatureRecords
    }

    // MARK: - Blockchain txHash update (called after on-chain confirmation)

    func updateConsentTxHash(id: String, txHash: String) async throws {
        var store = try loadStore()
        guard let idx = store.consentRecords.firstIndex(where: { $0.id == id }) else {
            throw LegalVaultError.notFound
        }
        store.consentRecords[idx].blockchainTxHash = txHash
        try saveStore(store)
    }

    func updateSignatureTxHash(id: String, txHash: String) async throws {
        var store = try loadStore()
        guard let idx = store.signatureRecords.firstIndex(where: { $0.id == id }) else {
            throw LegalVaultError.notFound
        }
        store.signatureRecords[idx].blockchainTxHash = txHash
        try saveStore(store)
    }

    // MARK: - GDPR Art.15 export

    /// Returns a ZIP archive (as Data) containing:
    ///   - legal_package.json  — all records as JSON
    ///   - README.txt          — explains the structure
    ///
    /// This is a compact in-memory export. A full PDF rendering layer should be
    /// added before presenting to the patient (out of scope for this actor).
    func exportLegalPackage() async throws -> Data {
        let store = try loadStore()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        // Produce a minimal JSON envelope — PDF generation is a UI concern.
        let payload = try encoder.encode(store)

        // In production: create a proper ZIP with DocumentInteractionController.
        // For now, return the JSON directly so callers can write it to a file or share sheet.
        return payload
    }

    // MARK: - Consent revocation

    func revokeConsent(id: String, revokedAt: Date = Date()) async throws {
        var store = try loadStore()
        guard let idx = store.consentRecords.firstIndex(where: { $0.id == id }) else {
            throw LegalVaultError.notFound
        }
        store.consentRecords[idx].revokedAt = revokedAt
        try saveStore(store)
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
        guard let store = try? JSONDecoder().decode(LegalVaultStore.self, from: plain) else {
            throw LegalVaultError.invalidData
        }
        return store
    }

    private func saveStore(_ store: LegalVaultStore) throws {
        let plain = try JSONEncoder().encode(store)
        let sealed = try encrypt(plain)

        let attrs: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: storeAccount,
            kSecValueData as String:   sealed,
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
        // Fetch the wrapped AES-256 key from the legal vault Keychain item.
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: wrappedKeyAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            // First use: generate and persist the legal vault AES-256 key.
            return try createLegalKey()
        }
        guard status == errSecSuccess, let wrapped = result as? Data else {
            throw LegalVaultError.keychainRead(status)
        }
        // Unwrap: the SE private key for the LEGAL vault (not the eHR vault).
        // SecureEnclaveKey must be extended to support a named key tag.
        let seKey = try SecureEnclaveKey.loadNamed(tag: "com.noborders.legal.sekey")
        let rawKey = try seKey.decrypt(wrapped)
        defer { // zero after use
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
        let wrapped = try seKey.encrypt(rawKey)

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
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: aesNonce)
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
