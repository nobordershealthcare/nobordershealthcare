// UserAgreementView.swift — Step 4: User Agreement with eIDAS Art.25 electronic signature.
//
// Scrollable legal agreement displayed in the user's selected language.
// Optional AI/research consent toggle (pre-unchecked).
// "I Agree — Sign" triggers an AdES electronic signature via SignatureButton,
// constituting a legally binding agreement under eIDAS Regulation Art.25.
//
// Legal bases recorded: GDPR Art.7, GDPR Art.9, eIDAS Art.25
// Signature record → Fabric channel 1 (signatures)
// After sign: coordinator.markUserAgreementComplete() via "Continue" button.

import SwiftUI

// MARK: - UserAgreementView

struct UserAgreementView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @AppStorage("appLanguage") private var appLanguage: String = "en"

    @State private var aiTrainingConsent: Bool = false
    @State private var signed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection
                        agreementTextCard
                        aiConsentToggle
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }

                signatureSection
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                    .background(.ultraThinMaterial)
            }
            .background(Color.appBg.ignoresSafeArea())
            .navigationTitle(s("User Agreement",
                               uk: "Угода користувача",
                               de: "Nutzungsvereinbarung",
                               pt: "Acordo de Utilizador",
                               ru: "Пользовательское соглашение"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.title2).foregroundStyle(Color.navy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s("Terms of Use & Privacy Agreement",
                           uk: "Угода про використання та конфіденційність",
                           de: "Nutzungsbedingungen & Datenschutzvereinbarung",
                           pt: "Termos de Uso & Acordo de Privacidade",
                           ru: "Условия использования и соглашение о конфиденциальности"))
                        .font(.title3).fontWeight(.bold)
                    Text("GDPR Art.9 · eIDAS Art.25")
                        .font(.subheadline).foregroundStyle(Color.navy)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(s("This agreement constitutes a legally binding electronic signature under EU eIDAS Regulation Article 25. By signing you consent to processing your special-category health data under GDPR Article 9.",
                       uk: "Ця угода є юридично обов'язковим електронним підписом відповідно до Статті 25 Регламенту ЄС eIDAS. Підписуючи, ви погоджуєтесь на обробку ваших медичних даних особливої категорії відповідно до Статті 9 GDPR.",
                       de: "Diese Vereinbarung stellt eine rechtsverbindliche elektronische Signatur gemäß Artikel 25 der EU-eIDAS-Verordnung dar. Mit der Unterzeichnung stimmen Sie der Verarbeitung Ihrer sensiblen Gesundheitsdaten gemäß DSGVO Artikel 9 zu.",
                       pt: "Este acordo constitui uma assinatura eletrónica juridicamente vinculativa ao abrigo do Artigo 25.º do Regulamento eIDAS da UE. Ao assinar, consente no tratamento dos seus dados de saúde de categoria especial ao abrigo do Artigo 9.º do RGPD.",
                       ru: "Данное соглашение является юридически обязательной электронной подписью в соответствии со Статьёй 25 Регламента ЕС eIDAS. Подписывая, вы соглашаетесь на обработку ваших медицинских данных особой категории в соответствии со Статьёй 9 GDPR."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Agreement text

    private var agreementTextCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(s("Terms of Service",
                   uk: "Умови надання послуг",
                   de: "Nutzungsbedingungen",
                   pt: "Termos de Serviço",
                   ru: "Условия использования"))
                .font(.headline)

            clause(
                "1",
                title: s("Service Description",
                         uk: "Опис послуги",
                         de: "Dienstbeschreibung",
                         pt: "Descrição do Serviço",
                         ru: "Описание услуги"),
                body: s("NoBorders Healthcare provides a patient-controlled emergency health record wallet. Your medical data is stored exclusively on your device using AES-256 encryption with a key secured in the iOS Secure Enclave. Your data is never uploaded to external servers without your explicit consent.",
                        uk: "NoBorders Healthcare надає пацієнт-контрольований гаманець для екстреної медичної документації. Ваші медичні дані зберігаються виключно на вашому пристрої з шифруванням AES-256 із ключем, захищеним у iOS Secure Enclave. Ваші дані ніколи не передаються на зовнішні сервери без вашої явної згоди.",
                        de: "NoBorders Healthcare bietet eine patientenkontrollierte Notfallkrankenakte. Ihre Gesundheitsdaten werden ausschließlich auf Ihrem Gerät mit AES-256-Verschlüsselung und einem im iOS Secure Enclave gesicherten Schlüssel gespeichert. Ihre Daten werden niemals ohne Ihre ausdrückliche Zustimmung auf externe Server hochgeladen.",
                        pt: "O NoBorders Healthcare fornece uma carteira de registos de saúde de emergência controlada pelo paciente. Os seus dados médicos são armazenados exclusivamente no seu dispositivo com encriptação AES-256 e uma chave protegida no iOS Secure Enclave. Os seus dados nunca são enviados para servidores externos sem o seu consentimento explícito.",
                        ru: "NoBorders Healthcare предоставляет кошелёк экстренной медицинской документации под управлением пациента. Ваши медицинские данные хранятся исключительно на вашем устройстве с шифрованием AES-256 с ключом, защищённым в iOS Secure Enclave. Ваши данные никогда не передаются на внешние серверы без вашего явного согласия.")
            )

            clause(
                "2",
                title: s("Data Ownership",
                         uk: "Власність даних",
                         de: "Dateneigentum",
                         pt: "Propriedade dos Dados",
                         ru: "Право собственности на данные"),
                body: s("You retain full ownership and control over all your health data. We do not claim any rights to your medical records. You may export, delete, or transfer all your data at any time from Settings → Privacy → Data Management.",
                        uk: "Ви зберігаєте повну власність та контроль над усіма вашими медичними даними. Ми не претендуємо на будь-які права на ваші медичні записи. Ви можете в будь-який час експортувати, видалити або передати всі свої дані через Налаштування → Конфіденційність → Управління даними.",
                        de: "Sie behalten das volle Eigentum und die Kontrolle über alle Ihre Gesundheitsdaten. Wir erheben keinen Anspruch auf Ihre medizinischen Unterlagen. Sie können Ihre Daten jederzeit unter Einstellungen → Datenschutz → Datenverwaltung exportieren, löschen oder übertragen.",
                        pt: "Mantém a propriedade total e o controlo sobre todos os seus dados de saúde. Não reivindicamos quaisquer direitos sobre os seus registos médicos. Pode exportar, eliminar ou transferir todos os seus dados a qualquer momento em Definições → Privacidade → Gestão de Dados.",
                        ru: "Вы сохраняете полное право собственности и контроль над всеми своими данными о здоровье. Мы не претендуем на какие-либо права на ваши медицинские записи. Вы можете экспортировать, удалить или передать все свои данные в любое время через Настройки → Конфиденциальность → Управление данными.")
            )

            clause(
                "3",
                title: s("Emergency Access",
                         uk: "Екстрений доступ",
                         de: "Notfallzugang",
                         pt: "Acesso de Emergência",
                         ru: "Экстренный доступ"),
                body: s("Your emergency QR code is generated locally and contains only the data subsets you have explicitly consented to share. Each QR token expires after 15 minutes. Emergency access events are logged on the blockchain audit trail (hash only — never content) for your protection under GDPR Art.15.",
                        uk: "Ваш екстрений QR-код генерується локально і містить лише ті підмножини даних, на спільний доступ до яких ви явно надали згоду. Кожен QR-токен дійсний 15 хвилин. Події доступу реєструються в блокчейн-журналі аудиту (лише хеш — без вмісту) для вашого захисту відповідно до GDPR Ст.15.",
                        de: "Ihr Notfall-QR-Code wird lokal generiert und enthält nur die Datenteilmengen, deren Weitergabe Sie ausdrücklich zugestimmt haben. Jedes QR-Token läuft nach 15 Minuten ab. Notfallzugriffe werden im Blockchain-Audit-Trail protokolliert (nur Hash — kein Inhalt) zu Ihrem Schutz gemäß DSGVO Art.15.",
                        pt: "O seu código QR de emergência é gerado localmente e contém apenas os subconjuntos de dados que consentiu explicitamente partilhar. Cada token QR expira após 15 minutos. Os acessos de emergência são registados na trilha de auditoria blockchain (apenas hash — nunca conteúdo) para a sua proteção ao abrigo do RGPD Art.15.",
                        ru: "Ваш экстренный QR-код генерируется локально и содержит только те подмножества данных, на совместное использование которых вы явно дали согласие. Каждый QR-токен действителен 15 минут. События доступа регистрируются в блокчейн-журнале аудита (только хеш — никогда содержимое) для вашей защиты в соответствии с GDPR Ст.15.")
            )

            clause(
                "4",
                title: "GDPR Art.9 — " + s("Special-Category Health Data",
                                           uk: "Дані особливої категорії про здоров'я",
                                           de: "Besondere Kategorien von Gesundheitsdaten",
                                           pt: "Dados de Saúde de Categoria Especial",
                                           ru: "Медицинские данные особой категории"),
                body: s("Health data is a special category under GDPR Article 9. Processing is only permitted with your explicit, freely given consent for each specific purpose. You may revoke any consent at any time in Settings → Privacy → Consent Management without affecting the lawfulness of prior processing.",
                        uk: "Медичні дані є особливою категорією відповідно до Статті 9 GDPR. Обробка дозволена лише з вашої явної, вільно наданої згоди для кожної конкретної мети. Ви можете відкликати будь-яку згоду в будь-який час у Налаштуваннях → Конфіденційність → Управління згодою, не впливаючи на законність попередньої обробки.",
                        de: "Gesundheitsdaten sind eine besondere Kategorie gemäß DSGVO Artikel 9. Die Verarbeitung ist nur mit Ihrer ausdrücklichen, frei gegebenen Einwilligung für jeden spezifischen Zweck erlaubt. Sie können jede Einwilligung jederzeit unter Einstellungen → Datenschutz → Einwilligungsverwaltung widerrufen, ohne die Rechtmäßigkeit der bisherigen Verarbeitung zu beeinträchtigen.",
                        pt: "Os dados de saúde são uma categoria especial ao abrigo do Artigo 9.º do RGPD. O tratamento só é permitido com o seu consentimento explícito e livremente prestado para cada finalidade específica. Pode revogar qualquer consentimento a qualquer momento em Definições → Privacidade → Gestão de Consentimentos sem afetar a licitude do tratamento anterior.",
                        ru: "Медицинские данные являются особой категорией в соответствии со Статьёй 9 GDPR. Обработка допускается только с вашего явного, свободно данного согласия на каждую конкретную цель. Вы можете отозвать любое согласие в любое время в Настройках → Конфиденциальность → Управление согласием, не затрагивая законность предыдущей обработки.")
            )

            clause(
                "5",
                title: s("Limitation of Liability",
                         uk: "Обмеження відповідальності",
                         de: "Haftungsbeschränkung",
                         pt: "Limitação de Responsabilidade",
                         ru: "Ограничение ответственности"),
                body: s("This app is not a medical device and does not provide medical advice, diagnosis, or treatment. Always consult a qualified healthcare professional. In jurisdictions where the app serves as a Class IIa medical device accessory under EU MDR 2017/745, regulatory documentation is available at noborders.health/regulatory.",
                        uk: "Цей додаток не є медичним приладом і не надає медичних порад, діагнозів або лікування. Завжди консультуйтеся з кваліфікованим медичним працівником. У юрисдикціях, де додаток є аксесуаром медичного пристрою класу IIa відповідно до EU MDR 2017/745, документація доступна на noborders.health/regulatory.",
                        de: "Diese App ist kein Medizinprodukt und gibt keine medizinischen Ratschläge, Diagnosen oder Behandlungen. Konsultieren Sie immer einen qualifizierten Angehörigen eines Gesundheitsberufs. In Rechtsordnungen, in denen die App als Klasse-IIa-Medizinproduktezubehör gemäß EU MDR 2017/745 dient, ist die Regulierungsdokumentation unter noborders.health/regulatory verfügbar.",
                        pt: "Esta aplicação não é um dispositivo médico e não fornece aconselhamento médico, diagnóstico ou tratamento. Consulte sempre um profissional de saúde qualificado. Nas jurisdições onde a aplicação serve como acessório de dispositivo médico de Classe IIa ao abrigo do EU MDR 2017/745, a documentação regulatória está disponível em noborders.health/regulatory.",
                        ru: "Это приложение не является медицинским устройством и не предоставляет медицинских советов, диагнозов или лечения. Всегда консультируйтесь с квалифицированным медицинским работником. В юрисдикциях, где приложение служит аксессуаром медицинского устройства класса IIa в соответствии с EU MDR 2017/745, регуляторная документация доступна на noborders.health/regulatory.")
            )
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func clause(_ number: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number). \(title)")
                .font(.subheadline).fontWeight(.semibold)
            Text(body)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - AI consent toggle

    private var aiConsentToggle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s("Optional: Research Contribution",
                   uk: "Необов'язково: Внесок у дослідження",
                   de: "Optional: Forschungsbeitrag",
                   pt: "Opcional: Contribuição para Investigação",
                   ru: "Необязательно: Вклад в исследования"))
                .font(.headline)

            Toggle(isOn: $aiTrainingConsent) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s("Allow anonymized data for medical research",
                           uk: "Дозволити використання анонімних даних для медичних досліджень",
                           de: "Anonymisierte Daten für medizinische Forschung erlauben",
                           pt: "Permitir dados anonimizados para investigação médica",
                           ru: "Разрешить анонимные данные для медицинских исследований"))
                        .font(.subheadline).fontWeight(.semibold)
                    Text(s("Fully anonymized only — no identifiers, no hashes, not re-identifiable. You can change this anytime in Settings → Privacy.",
                           uk: "Лише повністю анонімні дані — без ідентифікаторів, хешів, неможливо повторно ідентифікувати. Змінити можна будь-коли в Налаштуваннях → Конфіденційність.",
                           de: "Nur vollständig anonymisiert — keine Bezeichner, keine Hashes, nicht re-identifizierbar. Jederzeit änderbar unter Einstellungen → Datenschutz.",
                           pt: "Apenas totalmente anonimizados — sem identificadores, sem hashes, não re-identificáveis. Pode alterar a qualquer momento em Definições → Privacidade.",
                           ru: "Только полностью анонимные — без идентификаторов, без хешей, не поддаётся повторной идентификации. Изменить можно в любое время в Настройках → Конфиденциальность."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.navy)
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Signature section

    private var signatureSection: some View {
        VStack(spacing: 12) {
            if signed {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(s("Agreement signed",
                           uk: "Угоду підписано",
                           de: "Vereinbarung unterzeichnet",
                           pt: "Acordo assinado",
                           ru: "Соглашение подписано"))
                        .fontWeight(.semibold)
                }

                Button {
                    coordinator.markUserAgreementComplete()
                } label: {
                    Text(s("Continue",
                           uk: "Продовжити",
                           de: "Weiter",
                           pt: "Continuar",
                           ru: "Продолжить"))
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.navy)
            } else {
                SignatureButton(
                    document: buildAgreementDocument(),
                    documentType: .dataProcessingAuth,
                    consentItems: [],
                    legalBasis: [.gdprArt9, .gdprArt7, .eidasArt25],
                    jurisdictions: ["EU"],
                    adESText: s("By signing I agree to the NoBorders Healthcare Terms of Use and Privacy Agreement under GDPR Art.9 and eIDAS Art.25.",
                                uk: "Підписуючи, я погоджуюсь з Умовами використання та Угодою про конфіденційність NoBorders Healthcare відповідно до GDPR Ст.9 та eIDAS Ст.25.",
                                de: "Mit der Unterzeichnung stimme ich den Nutzungsbedingungen und der Datenschutzvereinbarung von NoBorders Healthcare gemäß DSGVO Art.9 und eIDAS Art.25 zu.",
                                pt: "Ao assinar concordo com os Termos de Uso e Acordo de Privacidade do NoBorders Healthcare ao abrigo do RGPD Art.9 e eIDAS Art.25.",
                                ru: "Подписывая, я соглашаюсь с Условиями использования и Соглашением о конфиденциальности NoBorders Healthcare в соответствии с GDPR Ст.9 и eIDAS Ст.25."),
                    label: s("I Agree — Sign",
                             uk: "Погоджуюсь — Підписати",
                             de: "Ich stimme zu — Unterschreiben",
                             pt: "Concordo — Assinar",
                             ru: "Согласен — Подписать")
                ) { _ in
                    signed = true
                }
            }
        }
    }

    // MARK: - Helpers

    private func buildAgreementDocument() -> Data {
        let payload: [String: Any] = [
            "type":              "user_agreement_v1",
            "language":          appLanguage,
            "aiTrainingConsent": aiTrainingConsent,
            "timestamp":         ISO8601DateFormatter().string(from: Date()),
            "version":           "1.0",
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private func s(_ en: String, uk: String, de: String, pt: String, ru: String) -> String {
        switch appLanguage {
        case "uk": return uk
        case "de": return de
        case "pt": return pt
        case "ru": return ru
        default:   return en
        }
    }
}

#Preview {
    UserAgreementView()
        .environmentObject(OnboardingCoordinator())
}
