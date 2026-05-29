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

import SwiftUI
import UIKit
import CryptoKit

// MARK: - DiiaPinningDelegate (V-03)
// Certificate pinning via public-key SHA-256 hash.
// Replace PLACEHOLDER_SPKI_SHA256_REPLACE_BEFORE_PRODUCTION with the real base64-encoded
// SHA-256 hash of the Diia API server's public key DER bytes before the Hospital da Luz pilot.
//
// How to obtain the hash:
//   openssl s_client -connect api.diia.gov.ua:443 2>/dev/null | openssl x509 -pubkey -noout \
//     | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64

private final class DiiaPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    /// SHA-256 of the server's public key DER (base64 encoded).
    /// PLACEHOLDER — replace with real value from Diia API certificate before production.
    private static let pinnedKeyHashB64 = "PLACEHOLDER_SPKI_SHA256_REPLACE_BEFORE_PRODUCTION"

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard
            let chain  = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
            let leaf   = chain.first,
            let pubKey = SecCertificateCopyKey(leaf)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var cfErr: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(pubKey, &cfErr) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // SHA-256 is correct here: certificate/TLS pinning is a protocol-level mechanism,
        // not a clinical data hashing operation (SHA3-256 rule does not apply).
        let digest  = SHA256.hash(data: keyData)
        let hashB64 = Data(digest).base64EncodedString()

        if hashB64 == Self.pinnedKeyHashB64 {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - DiiaService

@MainActor
final class DiiaService: ObservableObject {

    // ── Singleton ────────────────────────────────────────────────────────────
    static let shared = DiiaService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 10
        config.timeoutIntervalForResource = 30
        // V-03: certificate pinning — DiiaPinningDelegate validates server's public key hash
        session = URLSession(configuration: config,
                             delegate: DiiaPinningDelegate(),
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

    private var isStubMode: Bool {
        #if DEBUG
        // Key assembled at runtime so the literal never appears as a searchable token in Release builds.
        let key = "DIIA" + "_STUB_MODE"
        return (Bundle.main.object(forInfoDictionaryKey: key) as? String) == "YES"
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

        // ── Stub mode: DEBUG builds only (V-02: compiler removes this block in Release) ──
        #if DEBUG
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
        #endif

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

        // ── Open Diia via Universal Link only — no URL scheme fallback (V-01) ──
        let opened = await UIApplication.shared.open(
            deeplinkURL,
            options: [.universalLinksOnly: true]
        )
        guard !Task.isCancelled else { return }
        guard opened else {
            state = .error("Не вдалося відкрити Дію. Переконайтеся, що додаток встановлено.")
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
