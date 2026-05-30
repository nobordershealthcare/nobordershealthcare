// Kyber-1024 (NIST ML-KEM-1024) interface.
// ─────────────────────────────────────────────────────────────────────────────
// SECURITY BLOCKER — DO NOT SHIP WITHOUT COMPLETING THIS
// All three KyberOperations functions throw KyberError.notImplemented.
// Required action: integrate swift-oqs (liboqs Swift bindings).
//   1. Build liboqs as an XCFramework via scripts/build-liboqs-ios.sh
//   2. Replace each function body with the OQS_KEM_* call documented inline.
//   3. Remove the #warning and #error directives below.
// Blocked by: no swift-oqs XCFramework in ios/Frameworks/
// ─────────────────────────────────────────────────────────────────────────────
// Without Kyber:
//   • IPFS shard backup throws KyberError.notImplemented → patients cannot
//     recover their vault key if their device is lost or damaged.
//   • No post-quantum protection against Harvest Now / Decrypt Later attacks.
//   • CLAUDE.md invariant "key exchange via Kyber-1024 (NIST ML-KEM)" is violated.
// ─────────────────────────────────────────────────────────────────────────────

#if DEBUG

#warning("SECURITY BLOCKER: KyberOperations is not implemented — IPFS recovery is non-functional and PQC is absent. See inline TODO. Must be resolved before Hospital da Luz pilot.")

import Foundation

public struct KyberPublicKey: Sendable, Codable {
    public let rawBytes: Data

    public init(rawBytes: Data) throws {
        guard rawBytes.count == Kyber1024.publicKeyBytes else {
            throw KyberError.invalidKeySize(expected: Kyber1024.publicKeyBytes, got: rawBytes.count)
        }
        self.rawBytes = rawBytes
    }
}

public struct KyberPrivateKey: Sendable {
    public let rawBytes: Data

    public init(rawBytes: Data) throws {
        guard rawBytes.count == Kyber1024.secretKeyBytes else {
            throw KyberError.invalidKeySize(expected: Kyber1024.secretKeyBytes, got: rawBytes.count)
        }
        self.rawBytes = rawBytes
    }
}

public struct KyberEncapsulatedSecret: Sendable {
    public let ciphertext: Data   // 1568 bytes
    public let sharedSecret: Data // 32 bytes
}

public enum KyberError: Error, Sendable {
    case invalidKeySize(expected: Int, got: Int)
    case operationFailed
    case notImplemented
}

public enum Kyber1024 {
    public static let publicKeyBytes  = 1568
    public static let secretKeyBytes  = 3168
    public static let ciphertextBytes = 1568
    public static let sharedSecretBytes = 32
}

public enum KyberOperations {

    // Replace bodies with: OQS_KEM_keypair(OQS_KEM_alg_kyber_1024, pk, sk)
    public static func generateKeyPair() throws -> (publicKey: KyberPublicKey, privateKey: KyberPrivateKey) {
        throw KyberError.notImplemented
    }

    // Replace body with: OQS_KEM_encaps(OQS_KEM_alg_kyber_1024, ct, ss, pk)
    public static func encapsulate(using publicKey: KyberPublicKey) throws -> KyberEncapsulatedSecret {
        throw KyberError.notImplemented
    }

    // Replace body with: OQS_KEM_decaps(OQS_KEM_alg_kyber_1024, ss, ct, sk)
    public static func decapsulate(ciphertext: Data, using privateKey: KyberPrivateKey) throws -> Data {
        throw KyberError.notImplemented
    }
}

#else
#error("KyberOperations requires swift-oqs integration before a Release build. See ios/Sources/KyberKit/KyberOperations.swift for instructions.")
#endif
