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

    enum KeyError: Error {
        case keychainFailed(OSStatus)
        case kyberFailed(KyberError)
    }

    // MARK: - Ed25519

    func ed25519SigningKey() throws -> Curve25519.Signing.PrivateKey {
        if let k = try? loadEd25519() { return k }
        return try generateEd25519()
    }

    func ed25519PublicKeyData() throws -> Data {
        try ed25519SigningKey().publicKey.rawRepresentation
    }

    func sign(_ data: Data) throws -> Data {
        try ed25519SigningKey().signature(for: data)
    }

    private func generateEd25519() throws -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        var cfErr: Unmanaged<CFError>?
        guard let acl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.userPresence],
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
