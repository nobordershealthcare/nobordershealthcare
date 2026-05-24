// RegistrationView.swift — Onboarding Step 2: Create account.
//
// Fields: nickname (+ availability check), salutation, password (12+ chars, HIBP
//         k-anonymity check), security question + answer, email, phone (E.164).
//
// On submit:
//   • UserProfile created — password + answer SHA3-256 hashed
//   • UserProfileStore.save() → Keychain (com.noborders.user.profile)
//   • coordinator.markRegistrationComplete() → advance to Step 3 (Identity)
//
// HIBP check: CryptoKit.Insecure.SHA1 for k-anonymity protocol ONLY.
//   Only the first 5 hex chars of SHA1(password) are sent to api.pwnedpasswords.com.
//   The password itself is NEVER transmitted. This is a protocol-mandated SHA-1 use
//   (same exception class as PKCE/RFC 7636 — see CLAUDE.md).
//   Password STORAGE uses SHA3-256(salt + password) exclusively.

import SwiftUI
import CryptoKit

// MARK: - RegistrationView

struct RegistrationView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @AppStorage("appLanguage") private var lang: String = "en"

    // ── Form fields ───────────────────────────────────────────────────
    @State private var nickname        = ""
    @State private var salutation      = ""
    @State private var password        = ""
    @State private var passwordConfirm = ""
    @State private var selectedQ: SecurityQuestion = .firstPet
    @State private var customQ         = ""
    @State private var secAnswer       = ""
    @State private var email           = ""
    @State private var phone           = ""

    // ── Validation state ──────────────────────────────────────────────
    @State private var nicknameStatus: NicknameStatus = .idle
    @State private var strength: PwdStrength           = .empty
    @State private var hibp: HIBPStatus                = .idle
    @State private var emailError: String?             = nil
    @State private var phoneError: String?             = nil

    // ── Async tasks (debounce) ────────────────────────────────────────
    @State private var nickTask: Task<Void, Never>?    = nil
    @State private var hibpTask: Task<Void, Never>?    = nil

    // ── Submission ────────────────────────────────────────────────────
    @State private var submitting   = false
    @State private var submitError: String? = nil

    // ── Gate ──────────────────────────────────────────────────────────
    private var canAdvance: Bool {
        nicknameStatus == .available
            && password.count >= 12
            && password == passwordConfirm
            && hibp != .compromised
            && !secAnswer.trimmingCharacters(in: .whitespaces).isEmpty
            && emailError == nil && !email.isEmpty
            && phoneError == nil && !phone.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerSection
                        nicknameSection
                        salutationSection
                        passwordSection
                        securityQuestionSection
                        emailSection
                        phoneSection
                        if let err = submitError { errorBanner(err) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }

                // ── Pinned CTA ─────────────────────────────────────────
                Button { submit() } label: {
                    Group {
                        if submitting {
                            ProgressView().tint(.white).controlSize(.regular)
                        } else {
                            Text(s("Next", uk: "Далі", de: "Weiter", pt: "Seguinte", ru: "Далее"))
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canAdvance ? Color.navy : Color.navy.opacity(0.4))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(!canAdvance || submitting)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .navigationTitle(s("Create Account", uk: "Створити профіль", de: "Konto erstellen", pt: "Criar conta", ru: "Создать профиль"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: – Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s("Let's get to know you",
                   uk: "Давайте познайомимось",
                   de: "Lernen wir uns kennen",
                   pt: "Vamos nos conhecer",
                   ru: "Давайте познакомимся"))
                .font(.title3).fontWeight(.bold)
            Text(s("This stays on your device — never shared without your consent.",
                   uk: "Залишається на пристрої — без вашої згоди нічого не передається.",
                   de: "Bleibt auf Ihrem Gerät — ohne Ihre Zustimmung nicht weitergegeben.",
                   pt: "Fica no seu dispositivo — nunca partilhado sem o seu consentimento.",
                   ru: "Остаётся на устройстве — без вашего согласия ничего не передаётся."))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var nicknameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(s("Nickname", uk: "Нікнейм", de: "Benutzername", pt: "Apelido", ru: "Никнейм"))

            HStack(spacing: 8) {
                TextField("e.g. maria_k", text: $nickname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: nickname) { _, v in scheduleNicknameCheck(v) }
                    .styledField()

                switch nicknameStatus {
                case .checking:
                    ProgressView().controlSize(.small).frame(width: 20)
                case .available:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .taken:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }

            switch nicknameStatus {
            case .tooShort:
                Text(s("At least 3 characters", uk: "Мінімум 3 символи", de: "Mind. 3 Zeichen", pt: "Mín. 3 caracteres", ru: "Минимум 3 символа"))
                    .font(.caption).foregroundStyle(.secondary)
            case .taken:
                VStack(alignment: .leading, spacing: 6) {
                    Text(s("Taken — try one of these:", uk: "Зайнятий — спробуйте:", de: "Vergeben:", pt: "Ocupado — experimente:", ru: "Занят — попробуйте:"))
                        .font(.caption).foregroundStyle(.red)
                    HStack {
                        ForEach(suggestedNicknames, id: \.self) { suggestion in
                            Button { nickname = suggestion } label: {
                                Text(suggestion)
                                    .font(.caption).fontWeight(.semibold)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.navy.opacity(0.1))
                                    .clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            default: EmptyView()
            }
        }
    }

    private var salutationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(s("How should we address you?",
                         uk: "Як до Вас звертатись?",
                         de: "Wie sollen wir Sie ansprechen?",
                         pt: "Como devemos chamá-lo/a?",
                         ru: "Как к вам обращаться?"))
            TextField(
                s("e.g. Maria, Dr. Smith, Пані Олена",
                  uk: "напр. Пані Олена, Маріє",
                  de: "z.B. Frau Müller, Dr. Schmidt",
                  pt: "ex. Sra. Silva",
                  ru: "напр. Мария Ивановна"),
                text: $salutation)
                .styledField()
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(s("Recovery Password",
                         uk: "Пароль відновлення",
                         de: "Wiederherstellungspasswort",
                         pt: "Senha de recuperação",
                         ru: "Пароль восстановления"))

            SecureField(
                s("Min. 12 characters", uk: "Мін. 12 символів", de: "Mind. 12 Zeichen", pt: "Mín. 12 caracteres", ru: "Мин. 12 символов"),
                text: $password)
                .textContentType(.newPassword)
                .styledField(border: hibp == .compromised ? .red.opacity(0.5) : .clear)
                .onChange(of: password) { _, v in
                    strength = PwdStrength.evaluate(v)
                    scheduleHIBP(v)
                }

            if !password.isEmpty { strengthBar }

            SecureField(
                s("Confirm password", uk: "Підтвердити пароль", de: "Passwort bestätigen", pt: "Confirmar senha", ru: "Подтвердить пароль"),
                text: $passwordConfirm)
                .textContentType(.newPassword)
                .styledField(border: confirmBorderColor)

            VStack(alignment: .leading, spacing: 3) {
                ruleRow(s("At least 12 characters", uk: "Мінімум 12 символів", de: "Mind. 12 Zeichen", pt: "Mín. 12 caracteres", ru: "Минимум 12 символов"),
                        ok: password.count >= 12)
                ruleRow(s("Passwords match", uk: "Паролі збігаються", de: "Passwörter stimmen überein", pt: "Senhas coincidem", ru: "Пароли совпадают"),
                        ok: !passwordConfirm.isEmpty && password == passwordConfirm)
                if hibp == .compromised {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                        Text(s("This password appeared in known data breaches. Choose another.",
                               uk: "Цей пароль є в базах скомпрометованих паролів. Оберіть інший.",
                               de: "Dieses Passwort ist in bekannten Datenlecks aufgetaucht.",
                               pt: "Esta senha apareceu em violações conhecidas.",
                               ru: "Этот пароль найден в базах скомпрометированных паролей."))
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                if hibp == .checking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(s("Checking password safety…", uk: "Перевірка пароля…", de: "Passwort wird geprüft…", pt: "A verificar senha…", ru: "Проверка пароля…"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var strengthBar: some View {
        HStack(spacing: 4) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < strength.score ? strength.color : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
            Text(strength.label).font(.caption2).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var securityQuestionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(s("Security question", uk: "Контрольне питання", de: "Sicherheitsfrage", pt: "Pergunta de segurança", ru: "Контрольный вопрос"))

            Picker("", selection: $selectedQ) {
                ForEach(SecurityQuestion.allCases, id: \.self) { q in
                    Text(q.displayLabel).tag(q)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if selectedQ == .customQuestion {
                TextField(s("Type your own question…", uk: "Введіть своє запитання…", de: "Eigene Frage eingeben…", pt: "Escreva a sua pergunta…", ru: "Введите свой вопрос…"),
                          text: $customQ)
                    .styledField()
            }

            SecureField(s("Your answer (not case-sensitive)", uk: "Ваша відповідь", de: "Ihre Antwort", pt: "A sua resposta", ru: "Ваш ответ"),
                        text: $secAnswer)
                .textContentType(.none)
                .styledField()

            Text(s("Stored as a hash — never in plaintext.",
                   uk: "Зберігається як хеш — відкритий текст ніде не зберігається.",
                   de: "Als Hash gespeichert — nie im Klartext.",
                   pt: "Armazenado como hash — nunca em texto simples.",
                   ru: "Хранится как хеш — открытый текст нигде не сохраняется."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(s("Email address", uk: "Електронна пошта", de: "E-Mail-Adresse", pt: "Endereço de e-mail", ru: "Электронная почта"))
            TextField("you@example.com", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.emailAddress)
                .styledField(border: emailError != nil ? .red.opacity(0.5) : .clear)
                .onChange(of: email) { _, v in validateEmail(v) }
            if let err = emailError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(s("Mobile phone (international)", uk: "Мобільний (міжнародний формат)", de: "Mobiltelefon (international)", pt: "Telemóvel (internacional)", ru: "Мобильный (международный)"))
            TextField("+380 63 123 4567", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .styledField(border: phoneError != nil ? .red.opacity(0.5) : .clear)
                .onChange(of: phone) { _, v in validatePhone(v) }
            if let err = phoneError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text(s("Include country code, e.g. +380 63 123 4567",
                       uk: "З кодом країни, напр. +380 63 123 4567",
                       de: "Mit Ländervorwahl, z.B. +49 151 23456789",
                       pt: "Com indicativo, ex. +351 912 345 678",
                       ru: "С кодом страны, напр. +7 916 123 4567"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(msg).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: – View helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.subheadline).fontWeight(.semibold)
    }

    private func ruleRow(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary).font(.caption)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var confirmBorderColor: Color {
        guard !passwordConfirm.isEmpty else { return .clear }
        return password == passwordConfirm ? .green.opacity(0.4) : .red.opacity(0.5)
    }

    private var suggestedNicknames: [String] {
        let b = nickname.trimmingCharacters(in: .whitespaces)
        return ["\(b)_eu", "\(b)2025", "\(b)_nbh"]
    }

    // MARK: – Nickname availability

    enum NicknameStatus: Equatable { case idle, tooShort, checking, available, taken }

    private func scheduleNicknameCheck(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else {
            nicknameStatus = trimmed.isEmpty ? .idle : .tooShort
            return
        }
        nicknameStatus = .checking
        nickTask?.cancel()
        nickTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await checkNicknameAvailability(trimmed)
        }
    }

    @MainActor
    private func checkNicknameAvailability(_ name: String) async {
        // TODO: replace stub with GET /api/v1/users/nickname-check?value={name}
        try? await Task.sleep(nanoseconds: 300_000_000)
        let reserved = ["admin", "test", "root", "system", "noborders", "support", "health"]
        nicknameStatus = reserved.contains(name.lowercased()) ? .taken : .available
    }

    // MARK: – HIBP password check (k-anonymity, SHA-1 protocol-mandated)

    enum HIBPStatus: Equatable { case idle, checking, safe, compromised }

    private func scheduleHIBP(_ pwd: String) {
        guard pwd.count >= 12 else { hibp = .idle; return }
        hibp = .checking
        hibpTask?.cancel()
        hibpTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await checkHIBP(pwd)
        }
    }

    @MainActor
    private func checkHIBP(_ pwd: String) async {
        // Protocol-mandated Insecure.SHA1: only first 5 hex chars sent to HIBP API.
        // This is a k-anonymity range query — password is NEVER transmitted.
        guard let data = pwd.data(using: .utf8) else { hibp = .safe; return }
        let sha1   = Insecure.SHA1.hash(data: data)
        let hex    = sha1.map { String(format: "%02X", $0) }.joined()
        let prefix = String(hex.prefix(5))
        let suffix = String(hex.dropFirst(5))

        guard let url = URL(string: "https://api.pwnedpasswords.com/range/\(prefix)") else {
            hibp = .safe; return
        }
        var req = URLRequest(url: url)
        req.setValue("true", forHTTPHeaderField: "Add-Padding")
        req.timeoutInterval = 5

        do {
            let (responseData, _) = try await URLSession.shared.data(for: req)
            let body  = String(data: responseData, encoding: .utf8) ?? ""
            let found = body.split(separator: "\n").contains { $0.uppercased().hasPrefix(suffix) }
            hibp = found ? .compromised : .safe
        } catch {
            hibp = .safe   // network error → don't block user
        }
    }

    // MARK: – Validation

    private func validateEmail(_ v: String) {
        guard !v.isEmpty else { emailError = nil; return }
        let pattern = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        emailError = v.range(of: pattern, options: .regularExpression) == nil
            ? s("Enter a valid email address.",
                uk: "Введіть коректну email-адресу.",
                de: "Bitte gültige E-Mail-Adresse eingeben.",
                pt: "Introduza um endereço de e-mail válido.",
                ru: "Введите корректный адрес электронной почты.")
            : nil
        // TODO: corporate domain check via coordinator.corporateDomain when B2B flow added
    }

    private func validatePhone(_ v: String) {
        guard !v.isEmpty else { phoneError = nil; return }
        let digits = v.filter(\.isNumber)
        phoneError = (v.hasPrefix("+") && digits.count >= 7) ? nil
            : s("Enter a valid international number starting with +",
                uk: "Введіть номер у форматі +код_країни",
                de: "Bitte internationale Nummer mit + eingeben.",
                pt: "Número internacional a começar com +.",
                ru: "Введите номер в формате +код_страны.")
    }

    // MARK: – Submit

    private func submit() {
        guard canAdvance else { return }
        submitting  = true
        submitError = nil

        // Capture plaintext locally, zero @State immediately
        let pwd = password
        let ans = secAnswer
        password        = ""
        passwordConfirm = ""
        secAnswer       = ""

        Task {
            do {
                let question = selectedQ == .customQuestion
                    ? customQ.trimmingCharacters(in: .whitespaces)
                    : selectedQ.displayLabel

                var profile = UserProfile(
                    nickname:            nickname.trimmingCharacters(in: .whitespaces),
                    salutation:          salutation.trimmingCharacters(in: .whitespaces),
                    email:               email.lowercased().trimmingCharacters(in: .whitespaces),
                    phone:               phone.trimmingCharacters(in: .whitespaces),
                    securityQuestion:    question,
                    securityQuestionKey: selectedQ.rawValue,
                    securityAnswerHash:  "",
                    passwordHash:        "",
                    createdAt:           Date(),
                    updatedAt:           Date()
                )
                try profile.setPassword(pwd)
                try profile.setAnswer(ans)

                UserProfileStore.save(profile)
                // TODO: POST SHA3-256(nickname) to Gatekeeper → Fabric channel 2

                await MainActor.run {
                    submitting = false
                    coordinator.markRegistrationComplete()
                }
            } catch {
                await MainActor.run {
                    submitting  = false
                    submitError = error.localizedDescription
                }
            }
        }
    }

    // MARK: – Password strength

    struct PwdStrength {
        let score: Int
        let label: String
        let color: Color
        static let empty = PwdStrength(score: 0, label: "", color: .clear)

        static func evaluate(_ pwd: String) -> PwdStrength {
            var sc = 0
            if pwd.count >= 12 { sc += 1 }
            if pwd.count >= 16 { sc += 1 }
            if pwd.range(of: #"[A-Z]"#, options: .regularExpression) != nil { sc += 1 }
            if pwd.range(of: #"[^A-Za-z0-9]"#, options: .regularExpression) != nil { sc += 1 }
            let c = min(max(sc, pwd.isEmpty ? 0 : 1), 4)
            let labels = ["", "Weak", "Fair", "Strong", "Very Strong"]
            let colors: [Color] = [.clear, .red, .orange, .yellow, .green]
            return PwdStrength(score: c, label: labels[c], color: colors[c])
        }
    }

    // MARK: – Inline localisation helper

    private func s(_ en: String, uk: String, de: String, pt: String, ru: String) -> String {
        switch lang { case "uk": return uk; case "de": return de; case "pt": return pt; case "ru": return ru; default: return en }
    }
}

// MARK: – TextField style helper (file-private)

private extension View {
    func styledField(border: Color = .clear) -> some View {
        self
            .textFieldStyle(.plain)
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
    }
}

#Preview {
    RegistrationView()
        .environmentObject(OnboardingCoordinator())
}
