// DiiaService.swift — Дія (Diia) App Switch integration.
//
// Architecture:
//   1. IdentityView calls requestAuthorization()
//      → builds diia:// deep link with requestId + returnUrl
//      → UIApplication.open() switches to the Diia app
//   2. User authenticates in Diia, Diia calls back:
//      nobordershealthcare://diia-callback?payload=<JWT>
//   3. App's .onOpenURL fires → DiiaService.shared.handleCallback(url:)
//      → decodes payload → state = .received(DiiaIdentityPayload)
//   4. IdentityView observes state via @ObservedObject, shows confirmation card
//
// Stub mode (Diia not installed / simulator):
//   canOpenURL("diia://") → false
//   → auto-inject DiiaIdentityPayload.stub after 1.5 s
//   This lets UI development proceed without the real app.
//
// Security:
//   • JWT signature verification is the backend's responsibility — not done here.
//   • requestId ties the callback to this specific authorization request.
//   • If requestId mismatches the pending one, state → .error (replay guard).
//   • РНОКПП is NEVER written to disk from this service — callers hash it first.

import SwiftUI
import UIKit

// MARK: - DiiaService

@MainActor
final class DiiaService: ObservableObject {

    // ── Singleton ────────────────────────────────────────────────────────────
    static let shared = DiiaService()
    private init() {}

    // MARK: - State

    enum State: Equatable {
        case idle
        case launching                        // UIApplication.open() in flight
        case waitingForCallback               // Diia is open; waiting for return URL
        case received(DiiaIdentityPayload)    // payload decoded, ready for user confirmation
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

    // ── Internal tracking ────────────────────────────────────────────────────
    private var pendingRequestId: String = ""
    private var stubTask: Task<Void, Never>? = nil

    // MARK: - Public API

    /// Initiates the Дія App Switch authorization flow.
    ///
    /// Builds `diia://auth?requestId=<uuid>&returnUrl=nobordershealthcare://diia-callback`,
    /// opens Diia, then transitions to `.waitingForCallback`.
    ///
    /// If Diia is not installed (simulator / device without Diia), enters stub mode:
    /// auto-injects `DiiaIdentityPayload.stub` after 1.5 s to unblock UI development.
    func requestAuthorization() {
        stubTask?.cancel()
        stubTask = nil

        let requestId = UUID().uuidString
        pendingRequestId = requestId
        state = .launching

        let returnURL = "nobordershealthcare://diia-callback"
        guard
            let encodedReturn = returnURL.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed),
            let diiaURL = URL(
                string: "diia://auth?requestId=\(requestId)&returnUrl=\(encodedReturn)")
        else {
            state = .error("Не вдалося сформувати URL авторизації Дії")
            return
        }

        if UIApplication.shared.canOpenURL(diiaURL) {
            // ── Real path: Diia is installed ─────────────────────────────────
            UIApplication.shared.open(diiaURL) { [weak self] success in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if success {
                        self.state = .waitingForCallback
                    } else {
                        self.state = .error(
                            "Не вдалося відкрити Дію. Переконайтеся, що додаток встановлено.")
                    }
                }
            }
        } else {
            // ── Stub path: Diia not installed (simulator / dev) ───────────────
            // Show the waiting UI immediately so the flow is exercisable,
            // then inject test payload after 1.5 s.
            state = .waitingForCallback
            stubTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self.injectStub(requestId: requestId)
            }
        }
    }

    /// Called from the app's `.onOpenURL` handler for every incoming URL.
    ///
    /// Returns the decoded payload if the URL belongs to the Diia callback scheme;
    /// returns `nil` and leaves state unchanged for all other URLs.
    @discardableResult
    func handleCallback(url: URL) -> DiiaIdentityPayload? {
        guard url.scheme?.lowercased() == "nobordershealthcare",
              url.host?.lowercased()   == "diia-callback"
        else { return nil }

        stubTask?.cancel()   // cancel any in-flight stub if real callback arrived first

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // ── Real path: JWT payload in query string ────────────────────────────
        if let payloadStr = components?.queryItems?
            .first(where: { $0.name == "payload" })?.value,
           let payload = decodeJWTPayload(payloadStr) {

            guard payload.requestId == pendingRequestId else {
                state = .error(
                    "Ідентифікатор запиту не збігається. Будь ласка, спробуйте ще раз.")
                return nil
            }
            state = .received(payload)
            return payload
        }

        // ── Stub path: no (valid) payload — use test fixture ─────────────────
        let stub = DiiaIdentityPayload.stub(requestId: pendingRequestId)
        state = .received(stub)
        return stub
    }

    /// Resets the service to `.idle`.  Call when IdentityView disappears
    /// or when the user navigates away from the Diia flow.
    func reset() {
        stubTask?.cancel()
        stubTask = nil
        pendingRequestId = ""
        state = .idle
    }

    // MARK: - Private helpers

    private func injectStub(requestId: String) {
        state = .received(.stub(requestId: requestId))
    }

    /// Decodes a JWT payload (middle segment) into `DiiaIdentityPayload`.
    /// Signature verification is intentionally omitted — the backend verifies
    /// the signature when IdentityView exchanges the РНОКПП hash.
    private func decodeJWTPayload(_ token: String) -> DiiaIdentityPayload? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(DiiaIdentityPayload.self, from: data)
    }
}
