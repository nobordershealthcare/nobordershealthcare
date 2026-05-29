// WelcomeView.swift — Step 1: Purpose statement and language selection.
//
// Single purpose: "Emergency eHR — receive medical care anywhere in the EU
// regardless of language or institutional barriers."
//
// Language selection is the ONLY configuration on this screen.
// No skip, no "later", no demo mode — the only CTA is "Get Started".
//
// Layout: ScrollView+pinned-button (no NavigationStack — OnboardingFlowView
// provides the outer container).  Language grid is LazyVGrid 2-col so it
// scales cleanly to 10+ locales without any scroll issue.

import SwiftUI

// MARK: - WelcomeView

struct WelcomeView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @AppStorage("appLanguage") private var appLanguage: String = "en"

    @State private var scrolledToBottom = false

    // ── Localised strings — all UI text keyed to appLanguage ────────────────
    private struct L {
        let headline:     String
        let body:         String
        let badgeTitle:   String
        let badgeBody:    String
        let langHeader:   String
        let cta:          String
    }

    private var l: L {
        switch appLanguage {
        case "uk": return L(
            headline:   "Ваша екстрена медична ідентичність",
            body:       "Отримуйте медичну допомогу будь-де в ЄС незалежно від мовних та інституційних бар'єрів. Алергії, ліки, група крові — доступні лікарям швидкої за секунди, їхньою мовою, навіть без інтернету.",
            badgeTitle: "Контроль пацієнта · GDPR ст.9",
            badgeBody:  "Тільки ви вирішуєте, хто бачить ваші дані. Вся обробка — на пристрої. Діє законодавство ЄС.",
            langHeader: "Оберіть мову",
            cta:        "Розпочати"
        )
        case "de": return L(
            headline:   "Ihre Notfall-Gesundheitsidentität",
            body:       "Erhalten Sie medizinische Versorgung überall in der EU – unabhängig von Sprache oder institutionellen Barrieren. Allergien, Medikamente, Blutgruppe – in Sekunden auf Ihrer Sprache verfügbar, auch offline.",
            badgeTitle: "Patientenkontrolle · DSGVO Art.9",
            badgeBody:  "Nur Sie entscheiden, wer Ihre Daten sieht. Alle Verarbeitung auf dem Gerät. EU-Recht gilt.",
            langHeader: "Sprache auswählen",
            cta:        "Loslegen"
        )
        case "pt": return L(
            headline:   "A sua identidade de saúde de emergência",
            body:       "Receba cuidados médicos em qualquer lugar da UE, independentemente de barreiras linguísticas ou institucionais. Alergias, medicamentos, grupo sanguíneo — disponíveis para médicos de emergência em segundos, no idioma deles, offline.",
            badgeTitle: "Controlo pelo paciente · RGPD Art.9",
            badgeBody:  "Só você decide quem vê os seus dados. Todo o processamento é feito no dispositivo. Aplica-se a lei da UE.",
            langHeader: "Selecionar idioma",
            cta:        "Começar"
        )
        case "ar": return L(
            headline:   "هويتك الصحية في حالات الطوارئ",
            body:       "احصل على الرعاية الطبية في أي مكان داخل الاتحاد الأوروبي بغض النظر عن الحواجز اللغوية أو المؤسسية. الحساسيات والأدوية وفصيلة الدم — متاحة لأطباء الطوارئ في ثوانٍ، بلغتهم، دون إنترنت.",
            badgeTitle: "تحت سيطرة المريض · المادة 9 من اللائحة الأوروبية",
            badgeBody:  "أنت وحدك من يقرر من يرى بياناتك. جميع المعالجة على الجهاز. يسري قانون الاتحاد الأوروبي.",
            langHeader: "اختر اللغة",
            cta:        "ابدأ"
        )
        case "fr": return L(
            headline:   "Votre identité de santé d'urgence",
            body:       "Recevez des soins médicaux partout dans l'UE sans barrières linguistiques ni institutionnelles. Vos données critiques — allergies, médicaments, groupe sanguin — disponibles pour les médecins urgentistes en quelques secondes, dans leur langue, hors ligne.",
            badgeTitle: "Contrôle du patient · RGPD Art.9",
            badgeBody:  "Seul vous décidez qui voit vos données. Tout le traitement est effectué sur l'appareil. Le droit de l'UE s'applique.",
            langHeader: "Choisir la langue",
            cta:        "Commencer"
        )
        case "es": return L(
            headline:   "Tu identidad de salud de emergencia",
            body:       "Recibe atención médica en cualquier lugar de la UE sin barreras idiomáticas ni institucionales. Alergias, medicamentos, grupo sanguíneo — disponibles para médicos de urgencias en segundos, en su idioma, sin conexión.",
            badgeTitle: "Control del paciente · RGPD Art.9",
            badgeBody:  "Solo tú decides quién ve tus datos. Todo el procesamiento ocurre en el dispositivo. Se aplica la ley de la UE.",
            langHeader: "Seleccionar idioma",
            cta:        "Empezar"
        )
        case "it": return L(
            headline:   "La tua identità sanitaria di emergenza",
            body:       "Ricevi cure mediche ovunque nell'UE senza barriere linguistiche o istituzionali. Allergie, farmaci, gruppo sanguigno — disponibili per i medici d'urgenza in pochi secondi, nella loro lingua, anche offline.",
            badgeTitle: "Controllo del paziente · GDPR Art.9",
            badgeBody:  "Solo tu decidi chi vede i tuoi dati. Tutta la elaborazione avviene sul dispositivo. Si applica la legge dell'UE.",
            langHeader: "Seleziona la lingua",
            cta:        "Inizia"
        )
        case "pl": return L(
            headline:   "Twoja awaryjna tożsamość zdrowotna",
            body:       "Otrzymuj opiekę medyczną wszędzie w UE bez barier językowych ani instytucjonalnych. Alergie, leki, grupa krwi — dostępne dla lekarzy ratunkowych w sekundy, w ich języku, offline.",
            badgeTitle: "Kontrola pacjenta · RODO Art.9",
            badgeBody:  "Tylko Ty decydujesz, kto widzi Twoje dane. Całe przetwarzanie odbywa się na urządzeniu. Obowiązuje prawo UE.",
            langHeader: "Wybierz język",
            cta:        "Rozpocznij"
        )
        case "nl": return L(
            headline:   "Uw noodgezondheidsidentiteit",
            body:       "Ontvang medische zorg overal in de EU zonder taal- of institutionele barrières. Allergieën, medicijnen, bloedgroep — binnen seconden beschikbaar voor spoedartsen, in hun taal, offline.",
            badgeTitle: "Patiëntcontrole · AVG Art.9",
            badgeBody:  "Alleen u beslist wie uw gegevens ziet. Alle verwerking vindt op het apparaat plaats. EU-recht is van toepassing.",
            langHeader: "Selecteer taal",
            cta:        "Starten"
        )
        case "ro": return L(
            headline:   "Identitatea dvs. de sănătate de urgență",
            body:       "Primiți îngrijiri medicale oriunde în UE fără bariere lingvistice sau instituționale. Alergii, medicamente, grupă sanguină — disponibile medicilor de urgență în câteva secunde, în limba lor, offline.",
            badgeTitle: "Control pacient · GDPR Art.9",
            badgeBody:  "Numai dvs. decideți cine vă vede datele. Toată procesarea are loc pe dispozitiv. Se aplică legea UE.",
            langHeader: "Selectați limba",
            cta:        "Începe"
        )
        case "cs": return L(
            headline:   "Vaše nouzová zdravotní identita",
            body:       "Získávejte lékařskou péči kdekoli v EU bez jazykových nebo institucionálních bariér. Alergie, léky, krevní skupina — k dispozici záchranářům během sekund, v jejich jazyce, offline.",
            badgeTitle: "Kontrola pacienta · GDPR čl.9",
            badgeBody:  "Pouze vy rozhodujete, kdo vidí vaše data. Veškeré zpracování probíhá na zařízení. Platí právo EU.",
            langHeader: "Vyberte jazyk",
            cta:        "Začít"
        )
        case "sv": return L(
            headline:   "Din akuta hälsoidentitet",
            body:       "Få medicinsk vård var som helst i EU utan språkliga eller institutionella hinder. Allergier, läkemedel, blodgrupp — tillgängliga för akutläkare på sekunder, på deras språk, offline.",
            badgeTitle: "Patientkontroll · GDPR Art.9",
            badgeBody:  "Bara du bestämmer vem som ser dina uppgifter. All bearbetning sker på enheten. EU-lagstiftning gäller.",
            langHeader: "Välj språk",
            cta:        "Börja"
        )
        case "no": return L(
            headline:   "Din akutte helseidentitet",
            body:       "Motta medisinsk behandling hvor som helst i EU uten språklige eller institusjonelle barrierer. Allergier, medisiner, blodtype — tilgjengelig for akuttleger på sekunder, på deres språk, uten nett.",
            badgeTitle: "Pasientkontroll · GDPR Art.9",
            badgeBody:  "Bare du bestemmer hvem som ser dataene dine. All behandling skjer på enheten. EU-lov gjelder.",
            langHeader: "Velg språk",
            cta:        "Kom i gang"
        )
        case "fi": return L(
            headline:   "Hätäterveysidentiteettisi",
            body:       "Saa lääketieteellistä hoitoa missä tahansa EU:ssa kieli- tai institutionaalisista esteistä riippumatta. Allergiat, lääkkeet, verityyppi — saatavilla ensihoitolääkäreille sekunneissa, heidän kielellään, offline.",
            badgeTitle: "Potilaan hallinta · GDPR Art.9",
            badgeBody:  "Vain sinä päätät, kuka näkee tietosi. Kaikki käsittely tapahtuu laitteella. EU-laki pätee.",
            langHeader: "Valitse kieli",
            cta:        "Aloita"
        )
        case "ru": return L(
            headline:   "Ваша экстренная медицинская идентичность",
            body:       "Получайте медицинскую помощь в любой стране ЕС без языковых и институциональных барьеров. Аллергии, лекарства, группа крови — доступны врачам скорой за секунды, на их языке, без интернета.",
            badgeTitle: "Контроль пациента · GDPR ст.9",
            badgeBody:  "Только вы решаете, кто видит ваши данные. Вся обработка — на устройстве. Действует законодательство ЕС.",
            langHeader: "Выбрать язык",
            cta:        "Начать"
        )
        default: return L(
            headline:   "Your Emergency Health Identity",
            body:       "Receive medical care anywhere in the EU regardless of language or institutional barriers. Your critical health data — allergies, medications, blood type — available to emergency doctors in seconds, in their language, offline.",
            badgeTitle: "Patient-controlled · GDPR Art.9",
            badgeBody:  "Only you control who sees your data. All processing on-device. EU law applies.",
            langHeader: "Select your language",
            cta:        "Get Started"
        )
        }
    }

    // ── Language catalogue — add new locales here only ──────────────────────
    // Launch-required: en · uk · de · pt · ar
    // Interface + translation only (not launch-blocking): ru + EU locales
    private let supportedLanguages: [(code: String, name: String, flag: String)] = [
        // ── Launch languages ───────────────────────────────────────────────
        ("en", "English",    "🇬🇧"),
        ("uk", "Українська", "🇺🇦"),
        ("de", "Deutsch",    "🇩🇪"),
        ("pt", "Português",  "🇵🇹"),
        ("ar", "العربية",    "🇸🇦"),
        // ── EU expansion ──────────────────────────────────────────────────
        ("fr", "Français",   "🇫🇷"),
        ("es", "Español",    "🇪🇸"),
        ("it", "Italiano",   "🇮🇹"),
        ("pl", "Polski",     "🇵🇱"),
        ("nl", "Nederlands", "🇳🇱"),
        ("ro", "Română",     "🇷🇴"),
        ("cs", "Čeština",    "🇨🇿"),
        ("sv", "Svenska",    "🇸🇪"),
        ("no", "Norsk",      "🇳🇴"),
        ("fi", "Suomi",      "🇫🇮"),
        // ── Interface + document translation only ─────────────────────────
        ("ru", "Русский",    "🇷🇺"),
    ]

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        // No NavigationStack — OnboardingFlowView is the container
        VStack(spacing: 0) {
            // ScrollView takes all space above the pinned CTA button.
            // .overlay keeps sizing intact — ZStack would break scroll bounds.
            ScrollView {
                VStack(spacing: 0) {
                    // ── Logo + Brand ───────────────────────────────────────
                    logoSection

                    // ── Purpose statement ─────────────────────────────────
                    purposeStatement
                        .padding(.top, 8)

                    // ── Language grid ─────────────────────────────────────
                    languageGrid
                        .padding(.top, 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height
                    >= geo.contentSize.height - 24
            } action: { _, atBottom in
                withAnimation(.spring(duration: 0.3)) {
                    scrolledToBottom = atBottom
                }
            }
            .overlay(alignment: .bottom) {
                // ── Scroll-more hint: gradient + animated arrow ──────────
                if !scrolledToBottom {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [Color.appBg.opacity(0), Color.appBg.opacity(0.98)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 56)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.navy.opacity(0.85))
                            .clipShape(Circle())
                            .padding(.bottom, 8)
                            .symbolEffect(.bounce.down.byLayer, options: .repeating)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }

            // ── CTA — pinned to bottom, always visible ─────────────────
            Button {
                coordinator.advance(from: .welcome)
            } label: {
                Text(l.cta)
                    .font(.headline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.navy)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 36)
        }
        .background(Color.appBg.ignoresSafeArea())
    }

    // MARK: - Sections

    private var logoSection: some View {
        VStack(spacing: 8) {
            Image("NBHC logo")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)

            Text("Emergency eHR Wallet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var purposeStatement: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l.headline)
                .font(.title3)
                .fontWeight(.bold)

            Text(l.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.navy)
                VStack(alignment: .leading, spacing: 4) {
                    Text(l.badgeTitle)
                        .font(.subheadline).fontWeight(.semibold)
                    Text(l.badgeBody)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Language grid

    private var languageGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.langHeader)
                .font(.subheadline)
                .fontWeight(.semibold)

            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(supportedLanguages, id: \.code) { lang in
                    languageCell(lang)
                }
            }
        }
    }

    private func languageCell(_ lang: (code: String, name: String, flag: String)) -> some View {
        let selected = appLanguage == lang.code
        let isRTL    = lang.code == "ar"
        return Button {
            appLanguage = lang.code
            applyLocale(lang.code)
        } label: {
            HStack(spacing: 8) {
                // For RTL languages: checkmark leads, then name, then flag
                if isRTL {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.navy)
                    }
                    Text(lang.name)
                        .font(.subheadline)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Color.navy : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .environment(\.layoutDirection, .rightToLeft)
                    Spacer(minLength: 0)
                    Text(lang.flag).font(.title3)
                } else {
                    Text(lang.flag).font(.title3)
                    Text(lang.name)
                        .font(.subheadline)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Color.navy : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.navy)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                selected
                    ? Color.navy.opacity(0.10)
                    : Color(.secondarySystemGroupedBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selected ? Color.navy.opacity(0.4) : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Locale application

    /// Writes the selection and triggers environment locale reload.
    private func applyLocale(_ code: String) {
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        // Views reading @AppStorage("appLanguage") re-render immediately.
        // Full system locale restart happens on next launch for system strings.
    }
}

#Preview {
    WelcomeView()
        .environmentObject(OnboardingCoordinator())
}
