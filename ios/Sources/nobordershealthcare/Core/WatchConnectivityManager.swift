// WatchConnectivityManager.swift — iPhone ↔ Apple Watch QR data sync.
//
// iPhone side: responds to Watch requests for QR data.
// Watch side:  requests QR data from iPhone (see WatchContentView.swift).
//
// Message protocol:
//   Request:  { "request": "qr_data" }
//   Response: { "jwt": <String>, "stale": <Bool> }   — when full data QR available
//           | { "pid": <String> }                     — static QR fallback
//
// Security: JWT is the full signed token — same data the QR encodes.
// No plaintext PII in the message (JWT claims are signed + for display only).
//
// NOTE: Requires WatchConnectivity.framework + NSFaceIDUsageDescription in Watch target.

import Foundation
import WatchConnectivity

// MARK: - WatchConnectivityManager

final class WatchConnectivityManager: NSObject, WCSessionDelegate, @unchecked Sendable {

    static let shared = WatchConnectivityManager()

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - Watch → Phone request

    /// Called from Watch side to request QR data from the paired iPhone.
    func requestQRData(completion: @escaping ([String: Any]) -> Void) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isReachable
        else {
            // Phone not reachable — return empty (Watch will show placeholder)
            completion([:])
            return
        }

        WCSession.default.sendMessage(
            ["request": "qr_data"],
            replyHandler: completion,
            errorHandler: { _ in completion([:]) }
        )
    }

    // MARK: - Phone → Watch response (iPhone side handler)

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["request"] as? String == "qr_data" else {
            replyHandler([:])
            return
        }

        // Build response on main actor (vault access is actor-isolated)
        // Read from App Group shared container (nonisolated, no actor boundary crossing).
        // JWT caching in UserDefaults allows Watch to get the emergency QR without
        // crossing actor boundaries. Written by EmergencyCardService on token refresh.
        var response: [String: Any] = [:]
        let shared = UserDefaults(suiteName: "group.com.nobords.shared")
        if let jwt = shared?.string(forKey: "emergency_jwt") {
            response["jwt"]   = jwt
            response["stale"] = false
        } else if let pid = shared?.string(forKey: "patient_pid") {
            response["pid"] = pid
        }
        replyHandler(response)
    }

    // MARK: - WCSessionDelegate required methods

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
