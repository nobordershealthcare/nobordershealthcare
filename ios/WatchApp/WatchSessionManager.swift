// WatchSessionManager.swift — Watch side of WatchConnectivity.
// Sends a "qr_data" request to the paired iPhone and receives PNG-encoded QR.
// This file lives in the Watch app target only.

import Foundation
import WatchConnectivity

final class WatchSessionManager: NSObject, WCSessionDelegate, @unchecked Sendable {

    static let shared = WatchSessionManager()

    private var pendingHandlers: [([String: Any]) -> Void] = []

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - Request QR data from iPhone

    func requestQRData(completion: @escaping ([String: Any]) -> Void) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else {
            completion([:])
            return
        }
        guard WCSession.default.isReachable else {
            // Not reachable — return empty
            completion([:])
            return
        }
        WCSession.default.sendMessage(
            ["request": "qr_data"],
            replyHandler: completion,
            errorHandler: { _ in completion([:]) }
        )
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {}
}
