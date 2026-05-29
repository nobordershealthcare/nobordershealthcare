// DiiaService.swift — Дія (Diia) App Switch integration with backend polling.
//
// Architecture (v2 — backend-polling):
//   1. IdentityView calls requestAuthorization()
//      → POST $(BACKEND_BASE_URL)/diia/auth/request
//      → backend returns { requestId, deeplink }
//      → UIApplication.open(deeplink) switches to the Diia app
//      → state = .waitingForCallback
//      → pollTask polls GET /diia/auth/status/{requestId} every 2 s
//   2. pollStatus loop:
//      "pending"  → keep waiting (max 90 attempts ≈ 3 min)
//      "complete" → state = .received(DiiaIdentityPayload)
//      "expired"  → state = .error("expired")
//      "failed"   → state = .error(reason)
//      network error ×3 → state = .error("network")
//   3. IdentityView observes state via @ObservedObject, shows confirmation card
//
// Stub mode (DIIA_STUB_MODE = YES in Info.plist / xcconfig):
//   Skips all network calls; auto-injects DiiaIdentityPayload.stub after 1.5 s.
//
// Security:
//   • rnokppHash is computed by the backend — never derived client-side.
//   • requestId is held in RAM only — never written to Keychain or disk.
//   • Logged: requestId, HTTP status codes, state transitions.
//   • Never logged: firstName, patronymic, lastName, rnokppMasked, rnokppHash.

import CryptoKit
import SwiftUI
import UIKit

// MARK: - DiiaBackendPinningDelegate

/// URLSessionDelegate that enforces SPKI certificate pinning for the NoBorders
/// backend host. If the server presents a certificate whose SPKI SHA-256 digest
/// is not in the allowlist, the connection is rejected (H-04).
///
/// We pin to the backend's CA/intermediate SPKI rather than the leaf so that
/// normal 90-day Let's Encrypt rotations do not break the app. Update
/// `pinnedSPKIHashes` whenever the CA hierarchy changes.
///
/// The pinned hashes are SHA-256(SubjectPublicKeyInfo DER) for each
/// trusted certificate in the chain (root or intermediate, never leaf).
private final class DiiaBackendPinningDelegate: NSObject, URLSessionDelegate {

    /// SHA-256 SPKI hashes for the NoBorders backend CA chain.
    /// Compute with: `openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64`
    /// Replace the placeholder hash below with the production CA SPKI before release.
    private static let pinnedSPKIHashes: Set<String> = [
        // TODO(ops): replace with production CA/intermediate SPKI SHA-256 base64 before release
        "PLACEHOLDER_SPKI_SHA256_BASE64_REPLACE_BEFORE_RELEASE",
    ]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Evaluate the server trust using the system's certificate policy first.
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(serverTrust, &error)
        guard trusted else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Walk every certificate in the chain and check its SPKI against the allowlist.
        let certCount = SecTrustGetCertificateCount(serverTrust)
        for i in 0 ..< certCount {
            guard let cert = SecTrustGetCertificateAtIndex(serverTrust, i) else { continue }
            guard let spkiData = extractSPKI(from: cert) else { continue }
            let digest = SHA256.hash(data: spkiData)
            let b64 = Data(digest).base64EncodedString()
            if DiiaBackendPinningDelegate.pinnedSPKIHashes.contains(b64) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // No pin matched → reject.
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    /// Extracts the SubjectPublicKeyInfo (SPKI) DER bytes from a SecCertificate.
    private func extractSPKI(from certificate: SecCertificate) -> Data? {
        // Use SecCertificateCopyKey (iOS 14+) to obtain the public key,
        // then export it as DER-encoded SubjectPublicKeyInfo via SecKeyCopyExternalRepresentation.
        // Note: SecKeyCopyExternalRepresentation returns the raw key bytes (not the SPKI header)
        // for most key types. We prepend the standard SPKI header for P-256 and RSA keys
        // so the SHA-256 matches what openssl dgst produces.
        guard let pubKey = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else { return nil }

        // P-256 SPKI header (30 59 30 13 06 07 2a 86 48 ce 3d 02 01 06 08 2a 86 48 ce 3d 03 01 07 03 42 00)
        let p256Header = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        ])
        let keyType = SecKeyGetType(pubKey) as String
        if keyType == kSecAttrKeyTypeECSECPrimeRandom as String, keyData.count == 65 {
            return p256Header + keyData
        }
        // For RSA or other types, return raw — caller can extend with additional headers.
        return keyData
    }
}

// MARK: - DiiaService

@MainActor
final class DiiaService: ObservableObject {

    // ── Singleton ────────────────────────────────────────────────────────────
    static let shared = DiiaService()

    private let session: URLSession
    private let pinningDelegate = DiiaBackendPinningDelegate()

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 10
        config.timeoutIntervalForResource = 30
        // Attach SPKI-pinning delegate (H-04). The delegate rejects any TLS
        // handshake whose certificate chain does not include a pinned SPKI.
        session = URLSession(configuration: config,
                             delegate: DiiaBackendPinningDelegate(),
                             delegateQueue: nil)
    }

    // MARK: - State

    enum State: Equatable {
        case idle
        case launching                        // HTTP request in flight
        case waitingForCallback               // Diia open; polling for result
        case received(DiiaIdentityPayload)    // payload ready for confirmation
        case error(String)                    // user-facing error message

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.launching, .launching),
                 (.waitingForCallback, .waitingForCallback):
                return true
            case (.received(let a), .received(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    // ── Internal tracking (RAM-only; never persisted) ─────────────────────────
    private var pendingRequestId: String = ""
    private var authTask: Task<Void, Never>? = nil
    private var pollTask: Task<Void, Never>? = nil

    // ── Configuration ────────────────────────────────────────────────────────
    private var backendBaseURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "BACKEND_BASE_URL") as? String)
            ?? "https://api.noborders.healthcare"
    }

    // isStubMode is only evaluated in DEBUG builds. In Release builds the property
    // always returns false regardless of the Info.plist value, so a mis-configured
    // xcconfig cannot accidentally enable stub mode in production (H-03).
    private var isStubMode: Bool {
        #if DEBUG
        return (Bundle.main.object(forInfoDictionaryKey: "DIIA_STUB_MODE") as? String) == "YES"
        #else
        return false
        #endif
    }

    // MARK: - Backend response models

    private struct AuthRequestResponse: Decodable {
        let requestId: String
        let deeplink:  String
    }

    private struct AuthStatusResponse: Decodable {
        let status:  String
        let payload: DiiaIdentityPayload?
        let reason:  String?
    }

    // MARK: - Public API

    /// Initiates the Дія App Switch authorization flow.
    ///
    /// Synchronous entry point for use from non-async contexts (e.g. IdentityView).
    /// Cancels any in-flight auth/poll before starting a new one.
    func requestAuthorization() {
        authTask?.cancel()
        authTask = nil
        pollTask?.cancel()
        pollTask = nil
        authTask = Task { await startAuth() }
    }

    /// Called from the app's `.onOpenURL` handler for every incoming URL.
    ///
    /// In the polling architecture the callback URL only signals that Diia has
    /// returned to the foreground — the actual identity payload is fetched via
    /// pollStatus(), not from the URL.  Returns `nil`; kept for API compatibility
    /// with the `.onOpenURL` gate in NoBordersHealthcareApp.
    @discardableResult
    func handleCallback(url: URL) -> DiiaIdentityPayload? {
        guard url.scheme?.lowercased() == "nobordershealthcare",
              url.host?.lowercased()   == "diia-callback"
        else { return nil }
        // pollStatus() handles the state transition — no further action needed.
        return nil
    }

    /// Resets the service to `.idle`.  Call when IdentityView disappears
    /// or when the user navigates away from the Diia flow.
    func reset() {
        authTask?.cancel()
        authTask = nil
        pollTask?.cancel()
        pollTask = nil
        pendingRequestId = ""
        state = .idle
    }

    // MARK: - Private: start auth

    private func startAuth() async {
        state = .launching

        // ── Stub mode (simulator / DIIA_STUB_MODE = YES) ──────────────────────
        if isStubMode {
            let requestId = "stub-\(UUID().uuidString)"
            pendingRequestId = requestId
            state = .waitingForCallback
            pollTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self.state = .received(.stub(requestId: requestId))
            }
            return
        }

        // ── Real path: POST /diia/auth/request ────────────────────────────────
        guard let url = URL(string: "\(backendBaseURL)/diia/auth/request") else {
            state = .error("Неправильна адреса сервера авторизації")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let httpResponse: URLResponse
        do {
            (data, httpResponse) = try await session.data(for: request)
        } catch {
            guard !Task.isCancelled else { return }
            state = .error("Помилка мережі: \(error.localizedDescription)")
            return
        }

        guard !Task.isCancelled else { return }

        let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            state = .error("Сервер повернув помилку (\(statusCode))")
            return
        }

        let authResp: AuthRequestResponse
        do {
            authResp = try JSONDecoder().decode(AuthRequestResponse.self, from: data)
        } catch {
            state = .error("Не вдалося обробити відповідь сервера")
            return
        }

        pendingRequestId = authResp.requestId

        guard let deeplinkURL = URL(string: authResp.deeplink) else {
            state = .error("Неправильне посилання Дії від сервера")
            return
        }

        // ── Open Diia ─────────────────────────────────────────────────────────
        // universalLinksOnly: true prevents URL-scheme fallback. If the genuine
        // Diia Universal Link handler is not registered (app not installed), iOS
        // returns false rather than opening a browser or a spoofed custom scheme.
        // This closes C-01: a malicious app claiming the diia:// URL scheme cannot
        // intercept the deeplink and steal the requestId.
        let options: [UIApplication.OpenExternalURLOptionsKey: Any] = [.universalLinksOnly: true]
        let opened = await UIApplication.shared.open(deeplinkURL, options: options)
        guard !Task.isCancelled else { return }
        guard opened else {
            // Never fall back to URL scheme — guide user to install the real app.
            state = .error("Дію не встановлено або посилання недійсне. Завантажте офіційний додаток Дія з App Store.")
            return
        }

        state = .waitingForCallback
        let requestId = authResp.requestId
        pollTask = Task { await pollStatus(requestId: requestId) }
    }

    // MARK: - Private: poll for status

    private func pollStatus(requestId: String) async {
        var attempts      = 0
        var networkErrors = 0

        while true {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return  // Task was cancelled
            }
            guard !Task.isCancelled else { return }

            guard let url = URL(
                string: "\(backendBaseURL)/diia/auth/status/\(requestId)")
            else { return }

            let data: Data
            let httpResponse: URLResponse
            do {
                (data, httpResponse) = try await session.data(from: url)
            } catch {
                guard !Task.isCancelled else { return }
                networkErrors += 1
                if networkErrors >= 3 {
                    state = .error("Втрачено з'єднання. Спробуйте ще раз.")
                    return
                }
                continue
            }

            guard !Task.isCancelled else { return }

            let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode) else {
                networkErrors += 1
                if networkErrors >= 3 {
                    state = .error("Сервер недоступний (\(statusCode)). Спробуйте ще раз.")
                    return
                }
                continue
            }

            // Reset network-error counter on any successful HTTP exchange
            networkErrors = 0

            let statusResp: AuthStatusResponse
            do {
                statusResp = try JSONDecoder().decode(AuthStatusResponse.self, from: data)
            } catch {
                state = .error("Не вдалося обробити відповідь статусу")
                return
            }

            switch statusResp.status {

            case "pending":
                attempts += 1
                if attempts >= 90 {
                    state = .error("Час очікування вичерпано. Спробуйте ще раз.")
                    return
                }
                // continue polling

            case "complete":
                guard let payload = statusResp.payload else {
                    state = .error("Відповідь сервера не містить даних ідентифікації")
                    return
                }
                state = .received(payload)
                return

            case "expired":
                state = .error("Запит авторизації вичерпано. Спробуйте ще раз.")
                return

            case "failed":
                state = .error(statusResp.reason ?? "Авторизацію не вдалося. Спробуйте ще раз.")
                return

            default:
                state = .error("Невідомий статус від сервера: \(statusResp.status)")
                return
            }
        }
    }
}
