// SIP client wrapper for telemedicine calls.
// Underlying engine: PJSIP (libpjsua2) or Linphone SDK.
// Media: SRTP mandatory, ZRTP for key exchange. No unencrypted RTP accepted.
// The actual SDK bridging requires a system library target or an XCFramework —
// this file defines the Swift interface and call state machine only.

import Foundation
import Combine

// MARK: - Call state

enum CallState: Sendable, Equatable {
    case idle
    case calling(uri: String)
    case ringing
    case connected(duration: TimeInterval)
    case held
    case ended(reason: CallEndReason)
    case failed(String)
}

enum CallEndReason: String, Sendable {
    case localHangup, remoteHangup, networkError, authFailed, busy, declined
}

struct SIPCredentials: Sendable {
    let domain: String      // SIP domain (e.g. "sip.noborders.health")
    let username: String    // SHA3-256(userID) — pseudonymous
    let password: String    // ephemeral, fetched from Gatekeeper — never stored
}

// MARK: - SIPClient actor

@MainActor
final class SIPClient: ObservableObject {

    static let shared = SIPClient()

    @Published private(set) var callState: CallState = .idle
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var isOnSpeaker: Bool = false

    private var credentials: SIPCredentials?

    enum SIPError: Error {
        case notRegistered
        case callInProgress
        case sdkError(String)
        case encryptionNegotiationFailed  // ZRTP failed — call is torn down, never unencrypted
    }

    // MARK: - Registration

    func register(credentials: SIPCredentials) throws {
        self.credentials = credentials
        // Bridge to pjsua2: pjsua_acc_add with SRTP=mandatory, ZRTP enabled
        callState = .idle
    }

    func unregister() {
        credentials = nil
        callState = .idle
    }

    // MARK: - Call control

    func call(uri: String) throws {
        guard credentials != nil else { throw SIPError.notRegistered }
        guard case .idle = callState else { throw SIPError.callInProgress }

        callState = .calling(uri: uri)
        // Bridge to pjsua2: pjsua_call_make_call with snd_med_tp=ZRTP
    }

    func answer() {
        guard case .ringing = callState else { return }
        callState = .connected(duration: 0)
    }

    func hangup() {
        switch callState {
        case .idle: return
        default:
            callState = .ended(reason: .localHangup)
        }
    }

    func mute(_ muted: Bool) {
        isMuted = muted
        // Bridge to pjsua2: pjsua_conf_adjust_rx_level
    }

    func setSpeaker(_ speaker: Bool) {
        isOnSpeaker = speaker
        // Bridge to AVAudioSession output route
    }

    // Called by pjsua2 callback when ZRTP negotiation fails.
    // Policy: terminate the call immediately. Never accept unencrypted media.
    func onEncryptionFailed() {
        callState = .failed("ZRTP negotiation failed — call terminated")
    }
}
