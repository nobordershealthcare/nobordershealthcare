// FIPS 202 SHA3-256 — Keccak sponge, rate=136 bytes, output=32 bytes.
// Used everywhere a hash is needed; NEVER use SHA-256 (crypto/sha256 equivalent).

import Foundation

public enum SHA3_256 {

    public struct Digest: Sendable, Equatable, CustomStringConvertible {
        public let bytes: Data
        public var description: String { bytes.map { String(format: "%02x", $0) }.joined() }
    }

    public static func hash(data: Data) -> Digest {
        Digest(bytes: keccak256(Array(data)))
    }

    public static func hash(bytes: [UInt8]) -> Digest {
        Digest(bytes: keccak256(bytes))
    }

    // Validates a 64-char lowercase hex string as required by the project hashing standard.
    public static func isValidHex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

// MARK: - Keccak-f[1600] internals

private let rcConstants: [UInt64] = [
    0x0000000000000001, 0x0000000000008082,
    0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001,
    0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088,
    0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b,
    0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080,
    0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080,
    0x0000000080000001, 0x8000000080008008,
]

// rotations[x][y] — rho offsets, FIPS 202 Table 2
private let rotations: [[Int]] = [
    [ 0, 36,  3, 41, 18],
    [ 1, 44, 10, 45,  2],
    [62,  6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39,  8, 14],
]

@inline(__always)
private func rotl64(_ x: UInt64, _ n: Int) -> UInt64 {
    n == 0 ? x : (x << n) | (x >> (64 &- n))
}

private func keccakF1600(_ A: inout [UInt64]) {
    var B = [UInt64](repeating: 0, count: 25)
    var C = [UInt64](repeating: 0, count: 5)
    var D = [UInt64](repeating: 0, count: 5)

    for round in 0..<24 {
        // θ
        for x in 0..<5 {
            C[x] = A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20]
        }
        for x in 0..<5 {
            D[x] = C[(x + 4) % 5] ^ rotl64(C[(x + 1) % 5], 1)
        }
        for i in 0..<25 { A[i] ^= D[i % 5] }

        // ρ + π: B[y + 5*((2x+3y)%5)] = rot(A[x + 5y], rotations[x][y])
        for x in 0..<5 {
            for y in 0..<5 {
                B[y + 5 * ((2 * x + 3 * y) % 5)] = rotl64(A[x + 5 * y], rotations[x][y])
            }
        }

        // χ
        for x in 0..<5 {
            for y in 0..<5 {
                A[x + 5 * y] = B[x + 5 * y] ^ ((~B[(x + 1) % 5 + 5 * y]) & B[(x + 2) % 5 + 5 * y])
            }
        }

        // ι
        A[0] ^= rcConstants[round]
    }
}

private func keccak256(_ input: [UInt8]) -> Data {
    let rate = 136
    var state = [UInt64](repeating: 0, count: 25)

    var padded = input
    padded.append(0x06)  // SHA3 domain separator
    let fill = rate - (padded.count % rate)
    padded.append(contentsOf: [UInt8](repeating: 0, count: fill))
    padded[padded.count - 1] |= 0x80

    var offset = 0
    while offset < padded.count {
        for lane in 0..<(rate / 8) {
            var word: UInt64 = 0
            for b in 0..<8 {
                word |= UInt64(padded[offset + lane * 8 + b]) << (b * 8)
            }
            state[lane] ^= word
        }
        keccakF1600(&state)
        offset += rate
    }

    var out = [UInt8]()
    out.reserveCapacity(32)
    for lane in 0..<4 {
        let word = state[lane]
        for b in 0..<8 { out.append(UInt8((word >> (b * 8)) & 0xFF)) }
    }
    return Data(out)
}
