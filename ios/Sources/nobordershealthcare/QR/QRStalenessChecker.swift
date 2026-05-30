// QRStalenessChecker.swift — Compares the JWT `v` (version) field against the
// Channel 1 (signatures) Hyperledger Fabric blockchain version for the patient.
//
// A QR is stale when:
//   jwt.v < blockchain.latestVersion(for: jwt.sub)
//
// The check is best-effort and network-optional:
//   - No network → isStale = false (optimistic; don't block emergency use)
//   - Network error → isStale = false with a TTL retry
//   - Blockchain version ahead → isStale = true (show ⚠ badge)
//
// JWT parsing: base64url decode the claims segment only — no signature validation
// here (that's the physician-side verifier's job).
//
// LOGGING: Only SHA3-256(sub)[:8] in logs — never raw sub value.

import Foundation

// MARK: - QRStalenessChecker

enum QRStalenessChecker {

    // ── In-memory TTL cache to avoid hammering the blockchain API ───────────
    // nonisolated(unsafe): single-process read/write; always accessed from Task context.
    nonisolated(unsafe) private static var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 120   // 2 minutes

    private struct CacheEntry {
        let isStale: Bool
        let expiry:  Date
    }

    // MARK: - Public API

    /// Async check — returns true if the JWT's `v` field is behind the on-chain version.
    /// Always returns false when offline or on check failure (emergency-safe).
    static func isStale(jwt: String) async -> Bool {
        guard let claims = decodeClaims(jwt) else { return false }
        guard let localVersion = claims["v"] as? Int,
              let sub          = claims["sub"] as? String else { return false }

        let cacheKey = sub + ":\(localVersion)"
        if let cached = cache[cacheKey], cached.expiry > Date() {
            return cached.isStale
        }

        let stale = await fetchBlockchainVersion(sub: sub, localVersion: localVersion)
        cache[cacheKey] = CacheEntry(isStale: stale,
                                     expiry:  Date().addingTimeInterval(cacheTTL))
        return stale
    }

    /// Callback-based convenience wrapper for use from non-async contexts.
    static func check(jwt: String, completion: @escaping @Sendable (Bool) -> Void) {
        Task {
            let result = await isStale(jwt: jwt)
            completion(result)
        }
    }

    // MARK: - JWT claims extraction (no signature validation — read-only)

    static func decodeClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        // Base64url → base64 padding
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }

        guard let data = Data(base64Encoded: b64),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    // MARK: - Blockchain version fetch

    /// Queries the Gatekeeper /qr/version endpoint (authenticated, read-only).
    /// Returns false (not stale) on any network or auth error — emergency use MUST work offline.
    private static func fetchBlockchainVersion(sub: String, localVersion: Int) async -> Bool {
        guard let url = AppConfig.apiBaseURL
            .appendingPathComponent("qr/version")
            .addingQueryItem(name: "sub", value: sub) else {
            return false
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5   // short timeout — emergency screen must not hang

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chainVersion = json["version"] as? Int
            else { return false }
            return localVersion < chainVersion
        } catch {
            // Network unavailable or timeout — optimistic: not stale
            return false
        }
    }
}

// MARK: - URL helper

private extension URL {
    func addingQueryItem(name: String, value: String) -> URL? {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: name, value: value))
        comps.queryItems = items
        return comps.url
    }
}
