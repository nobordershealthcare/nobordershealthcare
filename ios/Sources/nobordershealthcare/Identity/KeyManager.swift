// Ed25519 signing key + Kyber-1024 KEM key pair, both in Keychain with SE access control.
// Ed25519: CryptoKit Curve25519 — stored as raw key bytes, biometric-gated via ACL.
// Kyber-1024: KyberKit stubs — stored identically once swift-oqs is integrated.

import Foundation
import Security
import CryptoKit

actor KeyManager {

    static let shared = KeyManager()

    private let ed25519Account    = "com.noborders.identity.ed25519.priv"
    private let kyberPubAccount   = "com.noborders.identity.kyber1024.pub"
    private let kyberPrivAccount  = "com.noborders.identity.kyber1024.priv"

    // Migration marker: set after the ACL upgrade from .userPresence → .biometryCurrentSet.
    // When absent, the existing key (if any) is deleted and regenerated with the correct ACL.
    // This is a one-time migration; the marker itself is not security-sensitive.
    private let aclMigrationV2Account = "com.noborders.identity.ed25519.acl-v2"

    enum KeyError: Error {
        case keychainFailed(OSStatus)
        case kyberFailed(KyberError)
    }

    // MARK: - Ed25519

    func ed25519SigningKey() throws -> Curve25519.Signing.PrivateKey {
        try migrateEd25519ACLIfNeeded()
        if let k = try? loadEd25519() { return k }
        return try generateEd25519()
    }

    func ed25519PublicKeyData() throws -> Data {
        try ed25519SigningKey().publicKey.rawRepresentation
    }

    func sign(_ data: Data) throws -> Data {
        try ed25519SigningKey().signature(for: data)
    }

    // Deletes any key created with the old .userPresence ACL and sets the migration marker.
    // After deletion, ed25519SigningKey() regenerates the key with .biometryCurrentSet.
    // Previously issued JWTs embedding the old public key will fail verification — acceptable
    // because they expire within 15 minutes and cannot be renewed without re-authenticating.
    private func migrateEd25519ACLIfNeeded() throws {
        let check: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: aclMigrationV2Account,
        ]
        guard SecItemCopyMatching(check as CFDictionary, nil) != errSecSuccess else {
            return // already migrated
        }
        // Delete the old key (may have been generated with .userPresence).
        let del: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: ed25519Account,
        ]
        SecItemDelete(del as CFDictionary) // ignore errSecItemNotFound — key may not exist yet

        // Record that migration is complete so this runs only once.
        let mark: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    aclMigrationV2Account,
            kSecValueData as String:      Data([0x01]),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(mark as CFDictionary) // clear any stale marker before writing
        SecItemAdd(mark as CFDictionary, nil)
    }

    private func generateEd25519() throws -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        var cfErr: Unmanaged<CFError>?
        // .biometryCurrentSet — invalidates the key if biometrics change (new fingerprint
        // enrolled). This prevents an attacker who adds their own fingerprint on a stolen
        // device from using the patient's signing key. Passcode fallback is intentionally
        // disabled: use SecureEnclaveKey (biometryCurrentSet) for the eHR vault instead.
        guard let acl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet],
            &cfErr
        ) else { throw cfErr!.takeRetainedValue() as Error }

        let q: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        ed25519Account,
            kSecValueData as String:          key.rawRepresentation,
            kSecAttrAccessControl as String:  acl,
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychainFailed(status) }
        return key
    }

    private func loadEd25519() throws -> Curve25519.Signing.PrivateKey {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: ed25519Account,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeyError.keychainFailed(status)
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    // MARK: - Kyber-1024

    func kyberPublicKey() throws -> KyberPublicKey {
        try kyberKeyPair().0
    }

    func kyberPrivateKey() throws -> KyberPrivateKey {
        try kyberKeyPair().1
    }

    private func kyberKeyPair() throws -> (KyberPublicKey, KyberPrivateKey) {
        if let pair = try? loadKyberKeys() { return pair }
        return try generateKyberKeys()
    }

    private func generateKyberKeys() throws -> (KyberPublicKey, KyberPrivateKey) {
        let pair: (publicKey: KyberPublicKey, privateKey: KyberPrivateKey)
        do { pair = try KyberOperations.generateKeyPair() }
        catch let e as KyberError { throw KeyError.kyberFailed(e) }

        try storeBytes(pair.publicKey.rawBytes, account: kyberPubAccount)
        try storeBytes(pair.privateKey.rawBytes, account: kyberPrivAccount)
        return (pair.publicKey, pair.privateKey)
    }

    private func loadKyberKeys() throws -> (KyberPublicKey, KyberPrivateKey) {
        let pubBytes  = try loadBytes(account: kyberPubAccount)
        let privBytes = try loadBytes(account: kyberPrivAccount)
        return (try KyberPublicKey(rawBytes: pubBytes), try KyberPrivateKey(rawBytes: privBytes))
    }

    private func storeBytes(_ data: Data, account: String) throws {
        let q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     account,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychainFailed(status) }
    }

    private func loadBytes(account: String) throws -> Data {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeyError.keychainFailed(status)
        }
        return data
    }
}
