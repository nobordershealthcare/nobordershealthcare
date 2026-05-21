import SwiftUI

struct CallView: View {

    @ObservedObject private var client = SIPClient.shared
    let targetURI: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                callStatusView
                Spacer()
                controlRow
            }
            .padding()
        }
        .onAppear {
            try? client.call(uri: targetURI)
        }
    }

    // MARK: - Subviews

    private var callStatusView: some View {
        VStack(spacing: 12) {
            Image(systemName: stateIcon)
                .font(.system(size: 64))
                .foregroundStyle(.white)
            Text(stateLabel)
                .font(.title2)
                .foregroundStyle(.white)
            if case .connected(let dur) = client.callState {
                Text(durationString(dur))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controlRow: some View {
        HStack(spacing: 40) {
            ControlButton(
                icon:     client.isMuted ? "mic.slash.fill" : "mic.fill",
                label:    client.isMuted ? "Unmute" : "Mute",
                tint:     client.isMuted ? .orange : .white
            ) { client.mute(!client.isMuted) }

            ControlButton(icon: "phone.down.fill", label: "End", tint: .red) {
                client.hangup()
            }

            ControlButton(
                icon:  client.isOnSpeaker ? "speaker.wave.3.fill" : "speaker.fill",
                label: "Speaker",
                tint:  client.isOnSpeaker ? .blue : .white
            ) { client.setSpeaker(!client.isOnSpeaker) }
        }
    }

    // MARK: - Helpers

    private var stateIcon: String {
        switch client.callState {
        case .calling:   return "phone.arrow.up.right"
        case .ringing:   return "phone.fill"
        case .connected: return "phone.fill"
        case .held:      return "pause.circle.fill"
        case .ended:     return "phone.down.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .idle:      return "phone"
        }
    }

    private var stateLabel: String {
        switch client.callState {
        case .calling(let uri): return "Calling \(uri)…"
        case .ringing:          return "Ringing…"
        case .connected:        return "Connected"
        case .held:             return "On hold"
        case .ended(let r):     return "Call ended (\(r.rawValue))"
        case .failed(let m):    return m
        case .idle:             return "Ready"
        }
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Control button

private struct ControlButton: View {
    let icon: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(tint)
                    .frame(width: 64, height: 64)
                    .background(.white.opacity(0.1))
                    .clipShape(Circle())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
