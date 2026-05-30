// EmergencyScreenView.swift — Redesigned emergency access screen.
//
// DESIGN DECISION (agreed):
//   REMOVED: patient name, DOB, language selector, allergies list, medications list.
//   All clinical data is inside the QR / at physician.noborders.healthcare/{pid}.
//   This screen has ONE job: show the QR as large as possible + call-for-help buttons.
//
// QR hierarchy:
//   Full data QR (JWT) → shown when wizard complete + EmergencyCardService has a token.
//   Static QR (physician URL) → fallback when no JWT available yet.
//
// Screenshot protection: iOS 17 isSceneCaptured → blur overlay.
// Dark navy background — NO glass — life-critical readability first.
//
// Covert profile: REMOVED (per architecture decision).

import SwiftUI

// MARK: - EmergencyScreenView

struct EmergencyScreenView: View {

    @Binding var isPresented: Bool
    @StateObject private var vm = EmergencyScreenViewModel()
    @Environment(\.isSceneCaptured) private var isSceneCaptured
    @StateObject private var network = NetworkCountryDetector.shared

    var body: some View {
        ZStack {
            // Dark navy — no glass, readability first
            Color(hex: "#0D1B2A").ignoresSafeArea()

            if isSceneCaptured {
                screenshotProtectionOverlay
            } else {
                content
            }
        }
        .onAppear { Task { await vm.loadQR() } }
        .statusBarHidden(true)
    }

    // MARK: - Main content

    private var content: some View {
        VStack(spacing: 20) {

            // ── Top bar ──────────────────────────────────────────────────
            HStack {
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                onlineIndicator
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // ── Title ────────────────────────────────────────────────────
            Text(vm.localizedTitle)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .tracking(1.5)

            // ── QR code — dominant element ───────────────────────────────
            QRDisplayView(
                mode: vm.hasFullDataQR ? .fullData : .staticLink,
                qrImage: vm.currentQRImage,
                isStale: vm.isStale,
                isOnline: network.isOnline,
                frameSize: 280
            )
            .padding(.horizontal, 20)

            // ── Regenerate (full data QR only) ────────────────────────────
            if vm.hasFullDataQR {
                Button {
                    Task { await vm.regenerateQR() }
                } label: {
                    Label("Regenerate QR", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .disabled(vm.isRegenerating)
            }

            Spacer()

            // ── Action buttons ────────────────────────────────────────────
            VStack(spacing: 12) {
                voiceInterpreterButton
                telemedicineButton
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
        }
    }

    // MARK: - Buttons

    private var voiceInterpreterButton: some View {
        Button(action: vm.startVoiceInterpreter) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Voice Interpreter")
                        .fontWeight(.semibold)
                    Text(vm.isVoiceAvailable
                         ? "Tap to start real-time translation"
                         : "Available after offline model download")
                        .font(.caption2)
                        .opacity(0.75)
                }
                Spacer()
                if !vm.isVoiceAvailable {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption)
                        .opacity(0.6)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 16)
            .background(
                vm.isVoiceAvailable
                    ? Color.red
                    : Color.red.opacity(0.35)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .disabled(!vm.isVoiceAvailable)
    }

    private var telemedicineButton: some View {
        Button(action: vm.startTelemedicine) {
            HStack(spacing: 10) {
                Image(systemName: "video.fill")
                Text("Telemedicine Call")
                    .fontWeight(.semibold)
                Spacer()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .background(Color.blue.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Accessories

    private var onlineIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(network.isOnline ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(network.isOnline ? "Online" : "Offline")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.12))
        .clipShape(Capsule())
    }

    private var screenshotProtectionOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Screen recording detected.\nEmergency QR is hidden.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6))
                    .font(.body)
            }
        }
    }
}

// MARK: - EmergencyScreenViewModel

@MainActor
final class EmergencyScreenViewModel: ObservableObject {

    @Published var currentQRImage: UIImage?
    @Published var hasFullDataQR:  Bool = false
    @Published var isStale:        Bool = false
    @Published var isRegenerating: Bool = false

    /// False until the offline SentencePiece/xLM model is downloaded and ready.
    @Published var isVoiceAvailable: Bool = false

    // Multi-language title — reads appLanguage from UserDefaults (set on WelcomeView).
    var localizedTitle: String {
        switch UserDefaults.standard.string(forKey: "appLanguage") ?? "en" {
        case "uk": return "ЕКСТРЕНА ДОПОМОГА"
        case "de": return "NOTFALLZUGANG"
        case "pt": return "ACESSO DE EMERGÊNCIA"
        case "ar": return "وصول الطوارئ"
        case "fr": return "ACCÈS D'URGENCE"
        case "es": return "ACCESO DE EMERGENCIA"
        case "it": return "ACCESSO D'EMERGENZA"
        case "pl": return "DOSTĘP RATUNKOWY"
        case "nl": return "NOODTOEGANG"
        case "ru": return "ЭКСТРЕННЫЙ ДОСТУП"
        default:   return "EMERGENCY ACCESS"
        }
    }

    // MARK: - QR loading

    func loadQR() async {
        // 1. Try full data QR from EmergencyCardService
        if let jwt = extractCurrentJWT() {
            currentQRImage = QRGenerator.generateFullDataQR(jwt: jwt)
            hasFullDataQR  = true
            isStale        = await QRStalenessChecker.isStale(jwt: jwt)
            return
        }

        // 2. Fallback: static QR from stored userIdHash
        let pid = loadStaticPID()
        currentQRImage = QRGenerator.generateStaticQR(pid: pid)
        hasFullDataQR  = false
        isStale        = false
    }

    func regenerateQR() async {
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            try await EmergencyCardService.shared.forceRefresh()
        } catch {
            // Biometric cancelled or failed — silently keep existing QR
        }
        await loadQR()
    }

    // MARK: - Actions

    func startVoiceInterpreter() {
        // TODO(post-pilot): trigger xLMEngine real-time interpreter
    }

    func startTelemedicine() {
        // TODO(post-pilot): open SIPClient telemedicine session
    }

    // MARK: - Private helpers

    private func extractCurrentJWT() -> String? {
        switch EmergencyCardService.shared.tokenState {
        case .valid(let jwt, _),
             .expiring(let jwt, _):
            return jwt
        default:
            return nil
        }
    }

    private func loadStaticPID() -> String {
        // Reads the stored userIdHash from the app group shared container
        // (written there during registration for lock-screen widget access).
        if let pid = UserDefaults(suiteName: "group.com.noborders.shared")?
            .string(forKey: "patient_pid") {
            return pid
        }
        // Fallback: static PID stored in App Group by RegistrationView
        return ""
    }
}

// MARK: - NetworkCountryDetector online helper

private extension NetworkCountryDetector {
    var isOnline: Bool {
        networkStatus != .offline
    }
}

// MARK: - Preview

#Preview {
    EmergencyScreenView(isPresented: .constant(true))
}
