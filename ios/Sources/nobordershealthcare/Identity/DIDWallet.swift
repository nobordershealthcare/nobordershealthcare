// W3C DID wallet for the patient's pseudonymous health identity.
// DID method: did:noborders:<SHA3-256(userID)>
// Credentials are Verifiable Credentials (W3C VC Data Model 2.0), signed with Ed25519.
// No real names or national IDs are stored — only the SHA3-256 pseudonym.

import Foundation
import CryptoKit

// MARK: - DID types

struct DID: Sendable, Hashable, CustomStringConvertible {
    let method: String  // always "noborders"
    let identifier: String  // SHA3-256 hex of userID

    var description: String { "did:\(method):\(identifier)" }

    static func make(from userIDHash: String) throws -> DID {
        guard SHA3_256.isValidHex(userIDHash) else {
            throw DIDError.invalidIdentifier
        }
        return DID(method: "noborders", identifier: userIDHash)
    }
}

struct VerifiableCredential: Sendable, Codable {
    let context: [String]
    let type: [String]
    let issuer: String
    let issuanceDate: Date
    let credentialSubject: [String: AnyCodable]
    let proof: CredentialProof
}

struct CredentialProof: Sendable, Codable {
    let type: String            // "Ed25519Signature2020"
    let created: Date
    let verificationMethod: String  // DID + "#key-1"
    let proofPurpose: String        // "assertionMethod"
    let proofValue: String          // base64url-encoded Ed25519 signature
}

struct AnyCodable: @unchecked Sendable, Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String:  try c.encode(s)
        case let i as Int:     try c.encode(i)
        case let b as Bool:    try c.encode(b)
        case let d as Double:  try c.encode(d)
        default:               try c.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let d = try? c.decode(Double.self) { value = d }
        else { value = NSNull() }
    }
}

enum DIDError: Error {
    case invalidIdentifier
    case signingFailed(Error)
    case noActiveDID
    case keychainFailed(OSStatus)
}

// MARK: - DIDWallet actor

actor DIDWallet {

    static let shared = DIDWallet()

    private let didAccount = "com.noborders.did.identifier"
    private var activeDID: DID?
    private var credentials: [VerifiableCredential] = []

    // Called once after Gatekeeper returns SHA3-256(userID).
    func enroll(userIDHash: String) throws {
        let did = try DID.make(from: userIDHash)
        activeDID = did
        try storeDID(did)
    }

    func currentDID() throws -> DID {
        if let did = activeDID { return did }
        return try loadDID()
    }

    func issueCredential(type: String, subject: [String: AnyCodable]) async throws -> VerifiableCredential {
        let did = try currentDID()
        let now = Date()
        let subjectWithID = subject.merging(["id": AnyCodable(did.description)]) { $1 }

        let payload = try JSONSerialization.data(withJSONObject: subjectWithID.mapValues { $0.value })
        let signature = try await KeyManager.shared.sign(payload)

        let proof = CredentialProof(
            type:               "Ed25519Signature2020",
            created:            now,
            verificationMethod: "\(did.description)#key-1",
            proofPurpose:       "assertionMethod",
            proofValue:         signature.base64EncodedString()
        )

        let vc = VerifiableCredential(
            context:           ["https://www.w3.org/2018/credentials/v1"],
            type:              ["VerifiableCredential", type],
            issuer:            did.description,
            issuanceDate:      now,
            credentialSubject: subjectWithID,
            proof:             proof
        )
        credentials.append(vc)
        return vc
    }

    func credentials(ofType type: String) -> [VerifiableCredential] {
        credentials.filter { $0.type.contains(type) }
    }

    /// Returns the SHA3-256 hex user ID hash (the DID identifier).
    /// Used throughout the app as the stable pseudonymous identity.
    func currentUserIdHash() throws -> String {
        try currentDID().identifier
    }

    // MARK: - Persistence

    private func storeDID(_ did: DID) throws {
        guard let data = did.identifier.data(using: .utf8) else { return }
        let q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     didAccount,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }

    private func loadDID() throws -> DID {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: didAccount,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let hex = String(data: data, encoding: .utf8)
        else { throw DIDError.noActiveDID }
        return try DID.make(from: hex)
    }
}
