// BiometricLockView.swift — Full-screen biometric gate.
//
// Shown on every app launch and every foreground resume when
// biometricLockEnabled == true (set automatically after the user
// signs the User Agreement in onboarding).
//
// Detects Face ID / Touch ID / Optic ID at runtime and adapts
// icon + label accordingly.  Prompts immediately on appear;
// shows a retry button when authentication fails.

import SwiftUI
import LocalAuthentication

// MARK: - BiometricLockView

struct BiometricLockView: View {

    /// Called on successful biometric challenge — parent flips isUnlocked.
    let onUnlock: () -> Void

    @AppStorage("appLanguage") private var lang: String = "en"

    @State private var isAuthenticating = false
    @State private var errorMessage: String? = nil

    // Resolved once in onAppear — avoids creating new LAContext on every render
    @State private var biometryIcon: String  = "faceid"
    @State private var biometryLabel: String = "Face ID"
    @State private var biometryAvailable: Bool = true

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Brand ─────────────────────────────────────────────────
                Image("NBHC logo")
                    .resizable().scaledToFit()
                    .frame(width: 72, height: 72)
                    .padding(.bottom, 28)

                // ── Biometry icon ─────────────────────────────────────────
                ZStack {
                    Circle()
                        .fill(Color.navy.opacity(0.08))
                        .frame(width: 100, height: 100)
                    Image(systemName: biometryIcon)
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(Color.navy)
                        .symbolEffect(.pulse, isActive: isAuthenticating)
                }
                .padding(.bottom, 24)

                // ── Labels ────────────────────────────────────────────────
                Text("#nobordershealthcare")
                    .font(.title2).fontWeight(.bold)
                    .foregroundStyle(Color.navy)

                Text(s("Your health wallet is locked",
                       uk: "Ваш медичний гаманець заблоковано",
                       de: "Ihr Gesundheits-Wallet ist gesperrt",
                       pt: "A sua carteira de saúde está bloqueada",
                       ru: "Ваш медицинский кошелёк заблокирован"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.horizontal, 32)

                // ── Error message ─────────────────────────────────────────
                if let err = errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                        Text(err)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                }

                Spacer()

                // ── Unlock button ─────────────────────────────────────────
                Button { authenticate() } label: {
                    HStack(spacing: 10) {
                        if isAuthenticating {
                            ProgressView().tint(.white).controlSize(.small)
                        } else {
                            Image(systemName: biometryIcon)
                        }
                        Text(
                            isAuthenticating
                                ? s("Authenticating…",
                                    uk: "Аутентифікація…",
                                    de: "Authentifizierung…",
                                    pt: "A autenticar…",
                                    ru: "Аутентификация…")
                                : unlockLabel
                        )
                        .fontWeight(.semibold)
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.navy)
                .disabled(isAuthenticating)
                .padding(.horizontal, 32)

                // Settings deep-link when biometrics aren't enrolled
                if !biometryAvailable {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text(s("Open Settings to enable Face ID / Touch ID",
                               uk: "Відкрити Налаштування для Face ID / Touch ID",
                               de: "Einstellungen öffnen (Face ID / Touch ID)",
                               pt: "Abrir Definições para Face ID / Touch ID",
                               ru: "Открыть Настройки для Face ID / Touch ID"))
                            .font(.caption)
                            .foregroundStyle(Color.navy)
                            .underline()
                    }
                    .padding(.top, 8)
                }

                Text(s("Protected by \(biometryLabel) · GDPR Art.9",
                       uk: "Захищено \(biometryLabel) · GDPR Ст.9",
                       de: "Geschützt durch \(biometryLabel) · DSGVO Art.9",
                       pt: "Protegido por \(biometryLabel) · RGPD Art.9",
                       ru: "Защищено \(biometryLabel) · GDPR Ст.9"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            resolvebiometryType()
            authenticate()
        }
    }

    // MARK: – Computed labels

    private var unlockLabel: String {
        errorMessage == nil
            ? s("Unlock with \(biometryLabel)",
                uk: "Розблокувати через \(biometryLabel)",
                de: "Mit \(biometryLabel) entsperren",
                pt: "Desbloquear com \(biometryLabel)",
                ru: "Разблокировать через \(biometryLabel)")
            : s("Try again",
                uk: "Спробувати ще",
                de: "Erneut versuchen",
                pt: "Tentar novamente",
                ru: "Повторить")
    }

    // MARK: – Biometry detection

    private func resolvebiometryType() {
        let ctx = LAContext()
        var err: NSError?
        biometryAvailable = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        switch ctx.biometryType {
        case .faceID:
            biometryIcon  = "faceid"
            biometryLabel = "Face ID"
        case .touchID:
            biometryIcon  = "touchid"
            biometryLabel = "Touch ID"
        case .opticID:
            biometryIcon  = "opticid"
            biometryLabel = "Optic ID"
        default:
            biometryIcon  = "lock.fill"
            biometryLabel = s("Biometrics",
                              uk: "Біометрія",
                              de: "Biometrie",
                              pt: "Biometria",
                              ru: "Биометрия")
        }
    }

    // MARK: – Authentication

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage     = nil

        let reason = s("Access your NoBorders Healthcare health wallet",
                       uk: "Доступ до медичного гаманця NoBorders Healthcare",
                       de: "Zugang zu Ihrem NoBorders Healthcare Gesundheits-Wallet",
                       pt: "Acesso à sua carteira de saúde NoBorders Healthcare",
                       ru: "Доступ к медицинскому кошельку NoBorders Healthcare")

        Task {
            do {
                try await BiometricAuth.shared.evaluate(reason: reason)
                await MainActor.run {
                    isAuthenticating = false
                    onUnlock()
                }
            } catch BiometricAuth.AuthError.unavailable {
                await MainActor.run {
                    isAuthenticating  = false
                    biometryAvailable = false
                    errorMessage = s(
                        "Biometric authentication is not set up on this device. Open Settings to enable Face ID or Touch ID.",
                        uk: "Біометричну аутентифікацію не налаштовано. Відкрийте Налаштування для Face ID або Touch ID.",
                        de: "Biometrische Authentifizierung ist nicht eingerichtet. Öffnen Sie die Einstellungen für Face ID oder Touch ID.",
                        pt: "A autenticação biométrica não está configurada. Abra as Definições para Face ID ou Touch ID.",
                        ru: "Биометрическая аутентификация не настроена. Откройте Настройки для Face ID или Touch ID.")
                }
            } catch {
                await MainActor.run {
                    isAuthenticating = false
                    errorMessage = s(
                        "Authentication failed. Tap to try again.",
                        uk: "Аутентифікація не вдалась. Натисніть для повторної спроби.",
                        de: "Authentifizierung fehlgeschlagen. Tippen zum erneuten Versuch.",
                        pt: "Autenticação falhada. Toque para tentar novamente.",
                        ru: "Аутентификация не удалась. Нажмите для повторной попытки.")
                }
            }
        }
    }

    // MARK: – Localisation

    private func s(_ en: String, uk: String, de: String, pt: String, ru: String) -> String {
        switch lang {
        case "uk": return uk
        case "de": return de
        case "pt": return pt
        case "ru": return ru
        default:   return en
        }
    }
}

#Preview {
    BiometricLockView { }
}
