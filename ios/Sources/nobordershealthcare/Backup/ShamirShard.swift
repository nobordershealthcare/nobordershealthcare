// Shamir Secret Sharing K=3/N=7 over GF(256).
// Splits the AES-256 vault key into 7 shards; any 3 reconstruct it.
// Each byte of the secret is processed independently using GF(2^8)
// with the AES irreducible polynomial x^8 + x^4 + x^3 + x + 1 (0x11B).
// Shards are encrypted with Kyber-1024 before distribution to IPFS.

import Foundation
import Security

// MARK: - GF(256) arithmetic

private enum GF256 {

    // AES polynomial: x^8 + x^4 + x^3 + x + 1
    private static let poly: UInt16 = 0x11B

    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var aa = UInt16(a)
        var bb = UInt16(b)
        for _ in 0..<8 {
            if bb & 1 != 0 { result ^= UInt8(aa & 0xFF) }
            aa <<= 1
            if aa & 0x100 != 0 { aa ^= poly }
            bb >>= 1
        }
        return result
    }

    static func add(_ a: UInt8, _ b: UInt8) -> UInt8 { a ^ b }

    // Evaluate polynomial f(x) = c[0] + c[1]*x + c[2]*x^2 + ... at point x
    static func eval(coefficients: [UInt8], at x: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var xPow: UInt8 = 1
        for c in coefficients {
            result = add(result, mul(c, xPow))
            xPow = mul(xPow, x)
        }
        return result
    }

    // Lagrange interpolation at x=0 to recover f(0) = secret byte
    static func interpolate(shares: [(x: UInt8, y: UInt8)]) -> UInt8 {
        var secret: UInt8 = 0
        for (i, si) in shares.enumerated() {
            var num: UInt8 = 1
            var den: UInt8 = 1
            for (j, sj) in shares.enumerated() where i != j {
                num = mul(num, sj.x)
                den = mul(den, add(si.x, sj.x))
            }
            let lagrange = mul(num, gfInverse(den))
            secret = add(secret, mul(si.y, lagrange))
        }
        return secret
    }

    // Extended Euclidean in GF(256) — inverse of a non-zero element
    static func gfInverse(_ a: UInt8) -> UInt8 {
        guard a != 0 else { return 0 }
        // Compute a^254 (Fermat's little theorem in GF(256): a^(256-1) = 1, so a^-1 = a^254)
        var r = a
        var result: UInt8 = 1
        for _ in 0..<7 {
            r = mul(r, r)
            result = mul(result, r)
        }
        // Final square
        return result
    }
}

// MARK: - Shamir implementation

struct ShardSet: Sendable, Codable {
    let threshold: Int      // K = 3
    let total: Int          // N = 7
    let shards: [Shard]

    struct Shard: Sendable, Codable, Identifiable {
        let id: Int         // 1-based index (x value in the polynomial)
        let bytes: Data     // one byte per secret byte
    }
}

enum ShamirShard {

    static let threshold = 3
    static let total     = 7

    // Splits `secret` (must be 32 bytes for AES-256) into 7 shards.
    static func split(secret: Data) throws -> ShardSet {
        guard secret.count == 32 else { throw ShamirError.invalidSecretLength(secret.count) }
        var shards = (1...total).map { ShardSet.Shard(id: $0, bytes: Data()) }

        let secretBytes = Array(secret)
        for byte in secretBytes {
            // Random polynomial coefficients: f(0) = byte, degree K-1
            var coeffs: [UInt8] = [byte]
            var randBytes = Data(count: threshold - 1)
            guard randBytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, threshold - 1, $0.baseAddress!) }) == errSecSuccess else {
                throw ShamirError.randomFailed
            }
            coeffs += Array(randBytes)

            for i in 0..<total {
                let x = UInt8(i + 1)
                let y = GF256.eval(coefficients: coeffs, at: x)
                shards[i] = ShardSet.Shard(id: shards[i].id, bytes: shards[i].bytes + Data([y]))
            }
        }

        return ShardSet(threshold: threshold, total: total, shards: shards)
    }

    // Reconstructs the secret from any `threshold` shards.
    static func reconstruct(shards: [ShardSet.Shard]) throws -> Data {
        guard shards.count >= threshold else { throw ShamirError.insufficientShards(shards.count) }
        let used = Array(shards.prefix(threshold))
        guard let byteCount = used.first?.bytes.count, byteCount == 32 else {
            throw ShamirError.malformedShard
        }

        var secret = Data(count: byteCount)
        for pos in 0..<byteCount {
            let points = used.map { (x: UInt8($0.id), y: Array($0.bytes)[pos]) }
            secret[pos] = GF256.interpolate(shares: points)
        }
        return secret
    }

    enum ShamirError: Error {
        case invalidSecretLength(Int)
        case randomFailed
        case insufficientShards(Int)
        case malformedShard
    }
}
