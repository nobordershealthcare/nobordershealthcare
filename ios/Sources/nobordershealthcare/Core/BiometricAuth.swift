import Foundation
import LocalAuthentication
import UIKit

actor BiometricAuth {

    static let shared = BiometricAuth()

    enum AuthError: Error, Sendable {
        case unavailable
        case denied
        case failed(Error)
    }

    func evaluate(reason: String) async throws {
        let ctx = LAContext()
        var evalError: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evalError) else {
            throw AuthError.unavailable
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, err in
                if let err { cont.resume(throwing: AuthError.failed(err)); return }
                ok ? cont.resume() : cont.resume(throwing: AuthError.denied)
            }
        }
    }

    // Blurs `view` whenever the screen is being captured (AirPlay, screenshot, screen recording).
    // Call once from @MainActor on the root view after launch.
    @MainActor
    static func registerCaptureBlur(for view: UIView) {
        NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak view] _ in
            view?.isHidden = UIScreen.main.isCaptured
        }
    }
}
