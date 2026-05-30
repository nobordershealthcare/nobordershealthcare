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
        // iPhone renders the QR PNG and sends it as Data to the Watch.
        // CoreImage is not available on watchOS, so the Watch can't render QR itself.
        // PNG data is read from App Group shared container (written on token refresh).
        var response: [String: Any] = [:]
        let shared = UserDefaults(suiteName: "group.com.noborders.shared")

        if let pngData = shared?.data(forKey: "emergency_qr_png") {
            // Full data QR — pre-rendered by EmergencyCardService on token refresh
            response["qr_png"] = pngData
            response["mode"]   = "full"
            response["stale"]  = shared?.bool(forKey: "emergency_qr_stale") ?? false
        } else if let pid = shared?.string(forKey: "patient_pid") {
            // Static QR — rendered on demand from pid
            let qrImage = QRGenerator.generateStaticQR(pid: pid,
                                                       size: CGSize(width: 160, height: 160))
            if let png = qrImage.flatMap({ $0.pngData() }) {
                response["qr_png"] = png
            }
            response["mode"]  = "static"
            response["stale"] = false
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
