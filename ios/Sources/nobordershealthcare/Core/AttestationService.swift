// DCAppAttestService wrapper.
// On first launch: generates an attestation key, attests it with Apple's CDN.
// On every sensitive API call: generates a per-request assertion.
// On jailbreak (isSupported == false or attest failure): enters permanent hard lockdown.

import Foundation
import DeviceCheck
import CryptoKit

actor AttestationService {

    static let shared = AttestationService()

    private let keyIDAccount   = "com.noborders.attest.keyid"
    private let lockdownAccount = "com.noborders.security.lockdown"

    enum AttestError: Error {
        case jailbreak
        case keychain(OSStatus)
        case attestFailed(Error)
        case assertionFailed(Error)
        case notAttested
    }

    // MARK: - Attestation (once per device)

    // Contacts Apple CDN. Returns raw attestationObject to send to Gatekeeper.
    // Apple's API requires SHA-256 of clientData — this is an Apple API boundary,
    // not our hashing standard. All our own IDs use SHA3-256 (SHA3Kit).
    func attest(serverChallenge: Data) async throws -> Data {
        guard DCAppAttestService.shared.isSupported else {
            await hardLockdown()
            throw AttestError.jailbreak
        }
        let keyId = try await resolveOrGenerateKeyId()
        let clientDataHash = Data(SHA256.hash(data: serverChallenge))

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) { obj, err in
                if let err { cont.resume(throwing: AttestError.attestFailed(err)); return }
                cont.resume(returning: obj ?? Data())
            }
        }
    }

    // MARK: - Assertion (per sensitive request)

    // Include the returned Data in the X-App-Attest-Assertion HTTP header.
    func generateAssertion(for requestBody: Data) async throws -> Data {
        guard DCAppAttestService.shared.isSupported else {
            await hardLockdown()
            throw AttestError.jailbreak
        }
        let keyId = try loadKeyId()
        let hash = Data(SHA256.hash(data: requestBody))

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: hash) { data, err in
                if let err { cont.resume(throwing: AttestError.assertionFailed(err)); return }
                cont.resume(returning: data ?? Data())
            }
        }
    }

    // MARK: - Jailbreak lockdown

    static func isLockedDown() -> Bool {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: "com.noborders.security.lockdown",
            kSecReturnData as String:  false,
        ]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    private func hardLockdown() async {
        // Wipe vault key — all encrypted data becomes permanently inaccessible.
        await VaultManager.shared.wipeWrappedKey()

        // Persist lockdown flag so subsequent launches also hard-stop.
        let flag: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     lockdownAccount,
            kSecValueData as String:       Data([0x01]),
            kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(flag as CFDictionary)
        SecItemAdd(flag as CFDictionary, nil)
    }

    // MARK: - Key ID management

    private func resolveOrGenerateKeyId() async throws -> String {
        if let existing = try? loadKeyId() { return existing }

        let keyId = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DCAppAttestService.shared.generateKey { id, err in
                if let err { cont.resume(throwing: AttestError.attestFailed(err)); return }
                cont.resume(returning: id ?? "")
            }
        }
        try storeKeyId(keyId)
        return keyId
    }

    private func loadKeyId() throws -> String {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keyIDAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let id = String(data: data, encoding: .utf8)
        else { throw AttestError.keychain(status) }
        return id
    }

    private func storeKeyId(_ id: String) throws {
        guard let data = id.data(using: .utf8) else { return }
        let q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     keyIDAccount,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw AttestError.keychain(status) }
    }
}
