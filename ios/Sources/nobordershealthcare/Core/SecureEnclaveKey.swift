// P-256 key permanently bound to the Secure Enclave coprocessor.
// Private key bytes never leave the SE; all signing/ECDH occurs inside it.

import Foundation
import Security

enum SecureEnclaveKey {

    static let tag = "com.noborders.se.master.p256".data(using: .utf8)!

    enum SEKeyError: Error {
        case notFound(OSStatus)
        case publicKeyUnavailable
        case deleteFailed(OSStatus)
        case generationFailed(CFError)
    }

    static func generate() throws -> SecKey {
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &cfError
        ) else {
            throw SEKeyError.generationFailed(cfError!.takeRetainedValue())
        }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String:       kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String:       kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String:    true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String:  access,
            ],
        ]

        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &cfError) else {
            throw SEKeyError.generationFailed(cfError!.takeRetainedValue())
        }
        return key
    }

    static func load() throws -> SecKey {
        try loadNamed(tag: String(data: tag, encoding: .utf8)!)
    }

    /// Load a Secure Enclave key by an arbitrary tag string.
    /// Used by LegalVaultManager (legal key) and VaultManager (eHR key)
    /// to retrieve their respective SE-bound private keys.
    static func loadNamed(tag tagString: String) throws -> SecKey {
        guard let tagData = tagString.data(using: .utf8) else {
            throw SEKeyError.notFound(errSecParam)
        }
        let query: [String: Any] = [
            kSecClass as String:              kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String:        kSecAttrTokenIDSecureEnclave,
            kSecReturnRef as String:          true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw SEKeyError.notFound(status) }
        return (result as! SecKey)
    }

    static func loadOrGenerate() throws -> SecKey {
        try ((try? load()) ?? generate())
    }

    static func publicKey(from privateKey: SecKey) throws -> SecKey {
        guard let pub = SecKeyCopyPublicKey(privateKey) else {
            throw SEKeyError.publicKeyUnavailable
        }
        return pub
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassKey,
            kSecAttrApplicationTag as String: tag,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SEKeyError.deleteFailed(status)
        }
    }
}
