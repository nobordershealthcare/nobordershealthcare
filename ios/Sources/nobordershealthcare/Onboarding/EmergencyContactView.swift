// EmergencyContactView.swift — Step 5: Emergency contact (optional).
//
// Collects how to reach the patient's trusted contact in an emergency:
//   – Salutation  — how the contact is addressed by responders
//   – Reach method: E.164 phone number  OR  messenger @handle + platform
//   – Messenger platforms: Telegram / WhatsApp / Instagram / Signal / Viber
//
// This step is OPTIONAL — the user may skip anytime and add the contact later
// in Settings → Emergency Contact.
//
// "Start Using NoBorders" — saves valid data then completes onboarding.
// "Skip for now"          — completes onboarding without saving.
//
// Storage: UserDefaults key "emergencyContact" (contact metadata, not health data).
// TODO: promote to UserProfile Keychain once profile contact fields are wired up.

import SwiftUI

// MARK: - MessengerPlatform

enum MessengerPlatform: String, Codable, CaseIterable {
    case telegram  = "telegram"
    case whatsapp  = "whatsapp"
    case instagram = "instagram"
    case signal    = "signal"
    case viber     = "viber"

    var displayName: String {
        switch self {
        case .telegram:  return "Telegram"
        case .whatsapp:  return "WhatsApp"
        case .instagram: return "Instagram"
        case .signal:    return "Signal"
        case .viber:     return "Viber"
        }
    }

    var iconName: String {
        switch self {
        case .telegram:  return "paperplane.fill"
        case .whatsapp:  return "phone.fill"
        case .instagram: return "camera.fill"
        case .signal:    return "lock.fill"
        case .viber:     return "bubble.left.fill"
        }
    }
}

// MARK: - ReachMethod

private enum ReachMethod: String {
    case phone     = "phone"
    case messenger = "messenger"
}

// MARK: - EmergencyContactView

struct EmergencyContactView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @AppStorage("appLanguage") private var appLanguage: String = "en"

    @State private var salutation:       String = ""
    @State private var reachMethod:      ReachMethod = .phone
    @State private var phoneNumber:      String = ""
    @State private var messengerHandle:  String = ""
    @State private var messengerPlatform: MessengerPlatform = .telegram

    // Valid when the selected reach-method has enough data to save.
    private var canSave: Bool {
        switch reachMethod {
        case .phone:
            return phoneNumber.hasPrefix("+") && phoneNumber.count >= 8
        case .messenger:
            return !messengerHandle.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection
                        salutationSection
                        reachMethodSection
                        reachDetailSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }

                bottomButtons
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                    .background(.ultraThinMaterial)
            }
            .background(Color.appBg.ignoresSafeArea())
            .navigationTitle(s("Emergency Contact",
                               uk: "Екстрений контакт",
                               de: "Notfallkontakt",
                               pt: "Contacto de Emergência",
                               ru: "Экстренный контакт"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s("Trusted Emergency Contact",
                   uk: "Довірений екстрений контакт",
                   de: "Vertrauenswürdiger Notfallkontakt",
                   pt: "Contacto de Emergência de Confiança",
                   ru: "Доверенный экстренный контакт"))
                .font(.title3).fontWeight(.bold)

            Text(s("If emergency responders need to reach someone on your behalf, who should they contact and how? This is stored only on your device and shown on your emergency QR card.",
                   uk: "Якщо рятувальникам потрібно зв'язатись з кимось від вашого імені — кому і як? Ця інформація зберігається лише на вашому пристрої і відображається на вашому екстреному QR-коді.",
                   de: "Wenn Rettungskräfte in Ihrem Namen jemanden kontaktieren müssen — wen und wie? Diese Daten werden nur auf Ihrem Gerät gespeichert und auf Ihrer Notfall-QR-Karte angezeigt.",
                   pt: "Se os socorristas precisarem de contactar alguém em seu nome, quem devem contactar e como? Estes dados são armazenados apenas no seu dispositivo e mostrados no seu cartão QR de emergência.",
                   ru: "Если службам экстренной помощи нужно связаться с кем-то от вашего имени — кому и как? Эти данные хранятся только на вашем устройстве и отображаются на вашей экстренной QR-карте."))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Salutation

    private var salutationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s("How to address them",
                   uk: "Як до них звертатись",
                   de: "Wie man sie anspricht",
                   pt: "Como os tratar",
                   ru: "Как к ним обращаться"))
                .font(.subheadline).fontWeight(.semibold)

            TextField(
                s("E.g. Mom, Dr. Nowak, Taras",
                  uk: "Напр.: Мама, Лікар Новак, Тарас",
                  de: "Z.B. Mama, Dr. Nowak, Taras",
                  pt: "Ex.: Mãe, Dr. Nowak, Taras",
                  ru: "Напр.: Мама, Д-р Новак, Тарас"),
                text: $salutation
            )
            .textContentType(.name)
            .autocorrectionDisabled()
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(s("Optional — appears on the emergency card shown to responders.",
                   uk: "Необов'язково — відображається на картці екстреної допомоги.",
                   de: "Optional — erscheint auf der Notfallkarte für Rettungskräfte.",
                   pt: "Opcional — aparece no cartão de emergência mostrado aos socorristas.",
                   ru: "Необязательно — отображается на карте экстренной помощи для спасателей."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Reach method toggle

    private var reachMethodSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s("How to reach them",
                   uk: "Як з ними зв'язатись",
                   de: "Wie man sie erreicht",
                   pt: "Como os contactar",
                   ru: "Как с ними связаться"))
                .font(.subheadline).fontWeight(.semibold)

            HStack(spacing: 0) {
                methodPill(.phone,
                           s("📞 Phone",
                             uk: "📞 Телефон",
                             de: "📞 Telefon",
                             pt: "📞 Telefone",
                             ru: "📞 Телефон"))
                methodPill(.messenger,
                           s("💬 Messenger",
                             uk: "💬 Месенджер",
                             de: "💬 Messenger",
                             pt: "💬 Messenger",
                             ru: "💬 Мессенджер"))
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
        }
    }

    private func methodPill(_ method: ReachMethod, _ label: String) -> some View {
        Button {
            withAnimation(.spring(duration: 0.2)) { reachMethod = method }
        } label: {
            Text(label)
                .font(.subheadline).fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(reachMethod == method ? Color.navy : Color.clear)
                .foregroundStyle(reachMethod == method ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.2), value: reachMethod)
    }

    // MARK: - Reach detail (phone or messenger)

    @ViewBuilder
    private var reachDetailSection: some View {
        switch reachMethod {
        case .phone:   phoneSection
        case .messenger: messengerSection
        }
    }

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s("Phone number (E.164 international format)",
                   uk: "Номер телефону (міжнародний формат E.164)",
                   de: "Telefonnummer (internationales E.164-Format)",
                   pt: "Número de telefone (formato internacional E.164)",
                   ru: "Номер телефона (международный формат E.164)"))
                .font(.subheadline).fontWeight(.semibold)

            TextField("+380 63 123 4567", text: $phoneNumber)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .padding(14)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if !phoneNumber.isEmpty && !phoneNumber.hasPrefix("+") {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                    Text(s("Must start with + and country code (e.g. +380)",
                           uk: "Має починатися з + і коду країни (напр. +380)",
                           de: "Muss mit + und Ländervorwahl beginnen (z.B. +49)",
                           pt: "Deve começar com + e indicativo do país (ex. +351)",
                           ru: "Должен начинаться с + и кода страны (напр. +7)"))
                        .font(.caption)
                }
                .foregroundStyle(.orange)
            }
        }
    }

    private var messengerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Platform chip row
            VStack(alignment: .leading, spacing: 8) {
                Text(s("Platform",
                       uk: "Платформа",
                       de: "Plattform",
                       pt: "Plataforma",
                       ru: "Платформа"))
                    .font(.subheadline).fontWeight(.semibold)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MessengerPlatform.allCases, id: \.self) { platform in
                            Button {
                                messengerPlatform = platform
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: platform.iconName).font(.caption)
                                    Text(platform.displayName)
                                        .font(.subheadline).fontWeight(.semibold)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(messengerPlatform == platform
                                            ? Color.navy
                                            : Color.secondary.opacity(0.12))
                                .foregroundStyle(messengerPlatform == platform
                                                 ? Color.white : Color.primary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .animation(.spring(duration: 0.2), value: messengerPlatform)
                        }
                    }
                }
            }

            // @handle field
            VStack(alignment: .leading, spacing: 8) {
                Text(s("Username / handle",
                       uk: "Ім'я користувача / нікнейм",
                       de: "Benutzername / Handle",
                       pt: "Nome de utilizador / handle",
                       ru: "Имя пользователя / хэндл"))
                    .font(.subheadline).fontWeight(.semibold)

                HStack(spacing: 0) {
                    Text("@")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                    TextField(
                        s("username",
                          uk: "імя_користувача",
                          de: "benutzername",
                          pt: "utilizador",
                          ru: "имя_пользователя"),
                        text: $messengerHandle
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.vertical, 14)
                    .padding(.trailing, 14)
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Bottom buttons

    private var bottomButtons: some View {
        VStack(spacing: 10) {
            Button {
                if canSave { save() }
                coordinator.markEmergencyContactComplete()
            } label: {
                Text(s("Start Using NoBorders",
                       uk: "Почати використання NoBorders",
                       de: "NoBorders starten",
                       pt: "Começar a usar o NoBorders",
                       ru: "Начать использование NoBorders"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.navy)

            Button {
                coordinator.markEmergencyContactComplete()
            } label: {
                Text(s("Skip for now",
                       uk: "Пропустити зараз",
                       de: "Jetzt überspringen",
                       pt: "Ignorar por agora",
                       ru: "Пропустить пока"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func save() {
        let contactData: [String: String] = [
            "salutation":        salutation,
            "reachMethod":       reachMethod.rawValue,
            "phoneNumber":       reachMethod == .phone     ? phoneNumber     : "",
            "messengerPlatform": reachMethod == .messenger ? messengerPlatform.rawValue : "",
            "messengerHandle":   reachMethod == .messenger ? messengerHandle : "",
        ]
        UserDefaults.standard.set(contactData, forKey: "emergencyContact")
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
    EmergencyContactView()
        .environmentObject(OnboardingCoordinator())
}
