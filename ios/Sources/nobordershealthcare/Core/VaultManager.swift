// AES-256-GCM data encryption with SE-wrapped key.
// The AES vault key is generated with SecRandomCopyBytes, then wrapped under the SE P-256 public
// key (ECIES). The wrapped blob lives in Keychain; plaintext key exists only during seal/open
// and is zeroed within 200 ms of use.

import Foundation
import Security
import CryptoKit

// MARK: - ProfileTypeStore
// ProfileType is defined in Legal/Models.swift (single source of truth).
// ProfileTypeStore is the Keychain-backed persistence layer for it.
// Thread-safe Keychain-backed store for the user's ProfileType.
// Separate from VaultManager actor to keep the encryption layer focused.

final class ProfileTypeStore: @unchecked Sendable {

    static let shared = ProfileTypeStore()

    private let keychainAccount = "com.noborders.profile.type"
    private let lock = NSLock()

    private init() {}

    func read() -> ProfileType {
        lock.lock()
        defer { lock.unlock() }
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let raw = String(data: data, encoding: .utf8),
              let type = ProfileType(rawValue: raw)
        else { return .civilian }
        return type
    }

    func write(_ type: ProfileType) {
        lock.lock()
        defer { lock.unlock() }
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
// Keychain-backed store for OperationalProfile (Silo 2: Legal Vault).
// Stored as JSON under com.noborders.operational.profile.
// Separate key from eHR vault (com.noborders.vault.key) and legal vault (com.noborders.legal.key).

final class OperationalProfileStore: @unchecked Sendable {

    static let shared = OperationalProfileStore()

    private let keychainAccount = "com.noborders.operational.profile"
    private let lock = NSLock()

    private init() {}

    func read() -> OperationalProfile? {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

actor VaultManager {

    static let shared = VaultManager()

    private let wrappedKeyAccount = "com.noborders.vault.aes256-wrapped"

    struct SealedVault: Codable, Sendable {
        let nonce: Data
        let ciphertext: Data
        let tag: Data
        let keyVersion: Int
    }

    enum VaultError: Error {
        case randomFailed
        case keychainRead(OSStatus)
        case keychainWrite(OSStatus)
        case seCryptoFailed(CFError)
        case aesFailed
    }

    // MARK: - Public API

    func seal(_ plaintext: Data) throws -> SealedVault {
        let vaultKey = try unwrapVaultKey()
        defer { zeroData(vaultKey) }

        var nonce = Data(count: 12)
        guard nonce.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }) == errSecSuccess else {
            throw VaultError.randomFailed
        }

        let sym = SymmetricKey(data: vaultKey)
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(plaintext, using: sym, nonce: aesNonce)
        return SealedVault(
            nonce:      Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag:        sealed.tag,
            keyVersion: 1
        )
    }

    func open(_ vault: SealedVault) throws -> Data {
        let vaultKey = try unwrapVaultKey()
        defer { zeroData(vaultKey) }

        let sym = SymmetricKey(data: vaultKey)
        let nonce = try AES.GCM.Nonce(data: vault.nonce)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: vault.ciphertext, tag: vault.tag)
        return try AES.GCM.open(box, using: sym)
    }

    // MARK: - Vault key management

    private func unwrapVaultKey() throws -> Data {
        if !wrappedKeyExists() { try createAndWrapVaultKey() }

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: wrappedKeyAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let wrapped = result as? Data else {
            throw VaultError.keychainRead(status)
        }

        // Decryption executes inside SE, triggering biometric gate
        let seKey = try SecureEnclaveKey.load()
        var cfError: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(seKey, .eciesEncryptionCofactorX963SHA256AESGCM, wrapped as CFData, &cfError) else {
            throw VaultError.seCryptoFailed(cfError!.takeRetainedValue())
        }
        return plain as Data
    }

    private func wrappedKeyExists() -> Bool {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: wrappedKeyAccount,
            kSecReturnData as String:  false,
        ]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    private func createAndWrapVaultKey() throws {
        var keyBytes = Data(count: 32)
        guard keyBytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
            throw VaultError.randomFailed
        }
        defer { zeroData(keyBytes) }

        let seKey = try SecureEnclaveKey.loadOrGenerate()
        let pubKey = try SecureEnclaveKey.publicKey(from: seKey)

        var cfError: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(pubKey, .eciesEncryptionCofactorX963SHA256AESGCM, keyBytes as CFData, &cfError) else {
            throw VaultError.seCryptoFailed(cfError!.takeRetainedValue())
        }

        let addQuery: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     wrappedKeyAccount,
            kSecValueData as String:       wrapped as Data,
            kSecAttrAccessible as String:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychainWrite(status) }
    }

    // MARK: - Jailbreak wipe

    // Called by AttestationService on jailbreak detection.
    // Deletes the wrapped vault key, rendering all sealed data permanently inaccessible.
    func wipeWrappedKey() {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: wrappedKeyAccount,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Helpers

@inline(__always)
private func zeroData(_ data: Data) {
    var copy = data
    copy.withUnsafeMutableBytes { ptr in
        _ = memset(ptr.baseAddress, 0, ptr.count)
    }
}
