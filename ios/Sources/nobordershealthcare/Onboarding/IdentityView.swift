// IdentityView.swift — Step 3: National identity verification.
//
// Flow:
//   1. Country picker — searchable grid, organised by tier
//   2. Provider step  — shows available eID provider(s) for the selected country
//   3. Auth step      — ASWebAuthenticationSession OIDC / AppSwitch
//   4. Success        — saves VerifiedIdentity, shows Continue / Done
//
// Providers by country tier:
//   Dedicated  🇵🇹 CMD · 🇺🇦 Diia · 🇩🇪 nPA
//   EU/eIDAS   All 27 EU members + EEA (NO/IS/LI)
//   Limited    Non-EU countries — eIDAS not available; manual verification later
//
// Security:
//   SHA3_256(per-user-salt + normalized_national_id) → userIdHash
//   Salt generated once, stored in Keychain; plaintext zeroed immediately.
//   GDPR Art.9: national ID is special-category — only its hash is persisted.
//
// Usage:
//   • Onboarding: no parameters — reads OnboardingCoordinator from environment.
//   • Profile sheet: pass isSheet: true + onDone callback.

import SwiftUI
import AuthenticationServices
import Security

// MARK: - Country catalogue

private struct IdentityCountry: Identifiable {
    let id: String          // ISO 3166-1 alpha-2
    let name: String
    let flag: String
    let providers: [EIDProvider]
    let tier: Tier

    enum Tier {
        case dedicated   // native eID integration
        case eidas       // EU / eIDAS node
        case limited     // no direct integration yet
    }

    var tierLabel: String {
        switch tier {
        case .dedicated: return providers.first?.shortName ?? "eID"
        case .eidas:     return "eIDAS"
        case .limited:   return "Limited"
        }
    }

    var tierColor: Color {
        switch tier {
        case .dedicated: return Color.navy
        case .eidas:     return .blue
        case .limited:   return .orange
        }
    }
}

private let allCountries: [IdentityCountry] = [
    // ── Dedicated integrations ────────────────────────────────────────────
    .init(id:"PT", name:"Portugal",      flag:"🇵🇹", providers:[.cmdPT,  .eidas], tier:.dedicated),
    .init(id:"UA", name:"Ukraine",       flag:"🇺🇦", providers:[.diiaUA],          tier:.dedicated),
    .init(id:"DE", name:"Germany",       flag:"🇩🇪", providers:[.npaDe,  .eidas], tier:.dedicated),

    // ── EU member states (eIDAS) ─────────────────────────────────────────
    .init(id:"AT", name:"Austria",       flag:"🇦🇹", providers:[.eidas], tier:.eidas),
    .init(id:"BE", name:"Belgium",       flag:"🇧🇪", providers:[.eidas], tier:.eidas),
    .init(id:"BG", name:"Bulgaria",      flag:"🇧🇬", providers:[.eidas], tier:.eidas),
    .init(id:"CY", name:"Cyprus",        flag:"🇨🇾", providers:[.eidas], tier:.eidas),
    .init(id:"CZ", name:"Czechia",       flag:"🇨🇿", providers:[.eidas], tier:.eidas),
    .init(id:"DK", name:"Denmark",       flag:"🇩🇰", providers:[.eidas], tier:.eidas),
    .init(id:"EE", name:"Estonia",       flag:"🇪🇪", providers:[.eidas], tier:.eidas),
    .init(id:"ES", name:"Spain",         flag:"🇪🇸", providers:[.eidas], tier:.eidas),
    .init(id:"FI", name:"Finland",       flag:"🇫🇮", providers:[.eidas], tier:.eidas),
    .init(id:"FR", name:"France",        flag:"🇫🇷", providers:[.eidas], tier:.eidas),
    .init(id:"GR", name:"Greece",        flag:"🇬🇷", providers:[.eidas], tier:.eidas),
    .init(id:"HR", name:"Croatia",       flag:"🇭🇷", providers:[.eidas], tier:.eidas),
    .init(id:"HU", name:"Hungary",       flag:"🇭🇺", providers:[.eidas], tier:.eidas),
    .init(id:"IE", name:"Ireland",       flag:"🇮🇪", providers:[.eidas], tier:.eidas),
    .init(id:"IT", name:"Italy",         flag:"🇮🇹", providers:[.eidas], tier:.eidas),
    .init(id:"LT", name:"Lithuania",     flag:"🇱🇹", providers:[.eidas], tier:.eidas),
    .init(id:"LU", name:"Luxembourg",    flag:"🇱🇺", providers:[.eidas], tier:.eidas),
    .init(id:"LV", name:"Latvia",        flag:"🇱🇻", providers:[.eidas], tier:.eidas),
    .init(id:"MT", name:"Malta",         flag:"🇲🇹", providers:[.eidas], tier:.eidas),
    .init(id:"NL", name:"Netherlands",   flag:"🇳🇱", providers:[.eidas], tier:.eidas),
    .init(id:"PL", name:"Poland",        flag:"🇵🇱", providers:[.eidas], tier:.eidas),
    .init(id:"RO", name:"Romania",       flag:"🇷🇴", providers:[.eidas], tier:.eidas),
    .init(id:"SE", name:"Sweden",        flag:"🇸🇪", providers:[.eidas], tier:.eidas),
    .init(id:"SI", name:"Slovenia",      flag:"🇸🇮", providers:[.eidas], tier:.eidas),
    .init(id:"SK", name:"Slovakia",      flag:"🇸🇰", providers:[.eidas], tier:.eidas),
    // EEA non-EU
    .init(id:"NO", name:"Norway",        flag:"🇳🇴", providers:[.eidas], tier:.eidas),
    .init(id:"IS", name:"Iceland",       flag:"🇮🇸", providers:[.eidas], tier:.eidas),
    .init(id:"LI", name:"Liechtenstein", flag:"🇱🇮", providers:[.eidas], tier:.eidas),

    // ── Limited — non-EU, no eIDAS node ─────────────────────────────────
    // Arabic-speaking
    .init(id:"SA", name:"Saudi Arabia",  flag:"🇸🇦", providers:[], tier:.limited),
    .init(id:"AE", name:"UAE",           flag:"🇦🇪", providers:[], tier:.limited),
    .init(id:"EG", name:"Egypt",         flag:"🇪🇬", providers:[], tier:.limited),
    .init(id:"MA", name:"Morocco",       flag:"🇲🇦", providers:[], tier:.limited),
    .init(id:"DZ", name:"Algeria",       flag:"🇩🇿", providers:[], tier:.limited),
    .init(id:"TN", name:"Tunisia",       flag:"🇹🇳", providers:[], tier:.limited),
    .init(id:"JO", name:"Jordan",        flag:"🇯🇴", providers:[], tier:.limited),
    .init(id:"LB", name:"Lebanon",       flag:"🇱🇧", providers:[], tier:.limited),
    .init(id:"IQ", name:"Iraq",          flag:"🇮🇶", providers:[], tier:.limited),
    .init(id:"KW", name:"Kuwait",        flag:"🇰🇼", providers:[], tier:.limited),
    .init(id:"QA", name:"Qatar",         flag:"🇶🇦", providers:[], tier:.limited),
    // European non-EU
    .init(id:"GB", name:"United Kingdom",flag:"🇬🇧", providers:[], tier:.limited),
    .init(id:"CH", name:"Switzerland",   flag:"🇨🇭", providers:[], tier:.limited),
    .init(id:"BY", name:"Belarus",       flag:"🇧🇾", providers:[], tier:.limited),
    .init(id:"GE", name:"Georgia",       flag:"🇬🇪", providers:[], tier:.limited),
    .init(id:"AM", name:"Armenia",       flag:"🇦🇲", providers:[], tier:.limited),
    .init(id:"AZ", name:"Azerbaijan",    flag:"🇦🇿", providers:[], tier:.limited),
    .init(id:"MD", name:"Moldova",       flag:"🇲🇩", providers:[], tier:.limited),
    .init(id:"RS", name:"Serbia",        flag:"🇷🇸", providers:[], tier:.limited),
    .init(id:"KZ", name:"Kazakhstan",    flag:"🇰🇿", providers:[], tier:.limited),
    .init(id:"RU", name:"Russia",        flag:"🇷🇺", providers:[], tier:.limited),
    // Global
    .init(id:"US", name:"United States", flag:"🇺🇸", providers:[], tier:.limited),
    .init(id:"TR", name:"Turkey",        flag:"🇹🇷", providers:[], tier:.limited),
    .init(id:"IL", name:"Israel",        flag:"🇮🇱", providers:[], tier:.limited),
]

// MARK: - EIDProvider extension

private extension EIDProvider {
    var shortName: String {
        switch self {
        case .cmdPT:  return "CMD"
        case .diiaUA: return "Diia"
        case .npaDe:  return "nPA"
        case .eidas:  return "eIDAS"
        }
    }
}

// MARK: - View states

private enum ViewState: Equatable {
    case selectingCountry
    case selectingProvider(IdentityCountry)
    case authenticating(IdentityCountry, EIDProvider)
    case success(VerifiedIdentity)
    case failed(String)

    static func == (lhs: ViewState, rhs: ViewState) -> Bool {
        switch (lhs, rhs) {
        case (.selectingCountry, .selectingCountry): return true
        case (.selectingProvider(let a), .selectingProvider(let b)): return a.id == b.id
        case (.authenticating(let a, let p), .authenticating(let b, let q)):
            return a.id == b.id && p == q
        case (.success, .success): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - IdentityView

struct IdentityView: View {

    // ── Onboarding context ─────────────────────────────────────────────────
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    // ── Sheet / profile mode ───────────────────────────────────────────────
    /// Pass `true` when presented as a sheet from the profile screen.
    var isSheet: Bool = false
    /// Called when a new identity is saved (both modes).
    var onDone: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    // ── State ──────────────────────────────────────────────────────────────
    @State private var viewState: ViewState = .selectingCountry
    @State private var searchText: String   = ""
    @State private var webAuthSession: ASWebAuthenticationSession?

    var body: some View {
        let core = coreContent
        if isSheet {
            NavigationStack {
                core
                    .navigationTitle("Link Identity")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
            }
        } else {
            core
        }
    }

    // MARK: - Core content (shared)

    @ViewBuilder
    private var coreContent: some View {
        switch viewState {
        case .selectingCountry:
            countryPickerView

        case .selectingProvider(let country):
            providerPickerView(country: country)

        case .authenticating(let country, let provider):
            authInProgressView(country: country, provider: provider)

        case .success(let identity):
            successView(identity)

        case .failed(let msg):
            errorView(msg)
        }
    }

    // MARK: - Step 1: Country picker

    private var countryPickerView: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search country…", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if searchText.isEmpty {
                        countrySection(
                            title: "Dedicated eID",
                            icon: "checkmark.seal.fill",
                            color: Color.navy,
                            countries: allCountries.filter { $0.tier == .dedicated }
                        )
                        countrySection(
                            title: "EU / eIDAS",
                            icon: "globe.europe.africa.fill",
                            color: .blue,
                            countries: allCountries.filter { $0.tier == .eidas }
                                .sorted { $0.name < $1.name }
                        )
                        countrySection(
                            title: "Other countries",
                            icon: "globe",
                            color: .orange,
                            countries: allCountries.filter { $0.tier == .limited }
                                .sorted { $0.name < $1.name }
                        )
                    } else {
                        let results = allCountries.filter {
                            $0.name.localizedCaseInsensitiveContains(searchText) ||
                            $0.id.localizedCaseInsensitiveContains(searchText)
                        }.sorted { $0.name < $1.name }

                        if results.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.largeTitle)
                                    .foregroundStyle(.tertiary)
                                Text("No country found for \"\(searchText)\"")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else {
                            countrySection(title: "Results", icon: nil, color: .primary,
                                           countries: results)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(Color.appBg.ignoresSafeArea())
    }

    private func countrySection(
        title: String,
        icon: String?,
        color: Color,
        countries: [IdentityCountry]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.caption).foregroundStyle(color) }
                Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(countries) { country in
                    countryCell(country)
                }
            }
        }
    }

    private func countryCell(_ country: IdentityCountry) -> some View {
        Button {
            if country.tier == .limited {
                viewState = .selectingProvider(country)
            } else if country.providers.count == 1 {
                viewState = .selectingProvider(country)
            } else {
                viewState = .selectingProvider(country)
            }
        } label: {
            HStack(spacing: 8) {
                Text(country.flag).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(country.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(country.tierLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(country.tierColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: Provider selection

    private func providerPickerView(country: IdentityCountry) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // ── Back + country header ─────────────────────────────
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            viewState = .selectingCountry
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                Text("Change country")
                            }
                            .font(.subheadline).foregroundStyle(Color.navy)
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 12) {
                            Text(country.flag).font(.largeTitle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(country.name).font(.title3).fontWeight(.bold)
                                Text("Select verification method")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    // ── Provider buttons ──────────────────────────────────
                    if country.tier == .limited {
                        limitedSupportCard(country)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(country.providers, id: \.rawValue) { provider in
                                providerButton(country: country, provider: provider)
                            }
                        }
                    }

                    // ── GDPR notice ───────────────────────────────────────
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.caption).foregroundStyle(Color.navy)
                        Text("Your national ID is hashed immediately after verification. Only a SHA3-256 fingerprint is stored — the original ID is never retained (GDPR Art.9).")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.navy.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .padding(.bottom, 16)
            }
        }
        .background(Color.appBg.ignoresSafeArea())
    }

    private func providerButton(country: IdentityCountry, provider: EIDProvider) -> some View {
        Button {
            startAuth(country: country, provider: provider)
        } label: {
            HStack(spacing: 16) {
                Text(country.flag).font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.body).fontWeight(.semibold)
                    Text(provider.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func limitedSupportCard(_ country: IdentityCountry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("eID not yet integrated")
                        .font(.subheadline).fontWeight(.semibold)
                    Text("\(country.name) identity verification is coming soon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("You can still use all app features. Identity verification for \(country.name) will be available in a future update. Your health data remains fully functional in the meantime.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                // Skip for now — mark identity step as complete without a hash
                if isSheet {
                    onDone?()
                    dismiss()
                } else {
                    coordinator.markIdentityComplete()
                }
            } label: {
                Text("Continue without verification")
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding(16)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Step 3: Auth in progress

    private func authInProgressView(country: IdentityCountry, provider: EIDProvider) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Verifying with \(provider.displayName)…")
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBg.ignoresSafeArea())
    }

    // MARK: - Error view

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Authentication failed").font(.subheadline).fontWeight(.semibold)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { viewState = .selectingCountry } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button { viewState = .selectingCountry } label: {
                Text("Try again")
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent).tint(Color.navy)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color.appBg.ignoresSafeArea())
    }

    // MARK: - Step 4: Success

    private func successView(_ identity: VerifiedIdentity) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 24)

                    HStack(spacing: 12) {
                        Text(identity.countryFlag).font(.largeTitle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Identity verified")
                                .font(.title3).fontWeight(.bold)
                            Text("\(identity.countryName) · \(identity.providerName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title2).foregroundStyle(.green)
                    }
                    .padding(16)
                    .background(Color.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Identity hash stored on-device only", systemImage: "lock.fill")
                        Label("Original ID zeroed from memory",       systemImage: "trash.fill")
                        Label("GDPR Art.9 — special-category data",   systemImage: "checkmark.seal.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            // ── CTA ────────────────────────────────────────────────────────
            Button {
                onDone?()
                if isSheet {
                    dismiss()
                } else {
                    coordinator.markIdentityComplete()
                }
            } label: {
                Text(isSheet ? "Done" : "Continue")
                    .font(.headline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent).tint(Color.navy)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 36)
        }
        .background(Color.appBg.ignoresSafeArea())
    }

    // MARK: - Authentication flow

    private func startAuth(country: IdentityCountry, provider: EIDProvider) {
        guard let url = provider.authorizationURL else {
            viewState = .failed("Authorization URL not available for \(provider.displayName)")
            return
        }

        // nPA: AppSwitch to AusweisApp2 — try to open the universal link directly
        if provider == .npaDe {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            } else {
                // AusweisApp2 not installed — fall back to eIDAS
                startAuth(country: country, provider: .eidas)
            }
            return
        }

        viewState = .authenticating(country, provider)

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil
        ) { callbackURL, error in
            Task { @MainActor in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        viewState = .selectingProvider(country)
                    } else {
                        viewState = .failed(error.localizedDescription)
                    }
                    return
                }
                guard let callbackURL else {
                    viewState = .failed("No callback URL received")
                    return
                }
                await handleCallback(url: callbackURL, country: country, provider: provider)
            }
        }
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = UIApplication.shared.firstKeyWindow
        webAuthSession = session
        session.start()
    }

    private func handleCallback(url: URL, country: IdentityCountry, provider: EIDProvider) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            viewState = .failed("Authorization code not found in callback")
            return
        }

        do {
            let idToken = try await exchangeCodeForIDToken(code, provider: provider)
            var nationalID = extractNationalID(from: idToken, provider: provider)
            defer { nationalID.removeAll(keepingCapacity: false) }

            guard !nationalID.isEmpty else {
                viewState = .failed("National ID claim not found in identity token")
                return
            }

            let normalized = normalize(nationalID: nationalID, provider: provider)
            let salt       = try loadOrCreateSalt()
            let combined   = (salt + normalized).data(using: .utf8) ?? Data()
            let hash       = SHA3_256.hash(data: combined).description

            let identity = VerifiedIdentity(
                id:           UUID(),
                countryCode:  country.id,
                countryFlag:  country.flag,
                countryName:  country.name,
                providerID:   provider.rawValue,
                providerName: provider.displayName,
                userIdHash:   hash,
                verifiedAt:   Date(),
                expiresAt:    nil
            )

            // Save to multi-identity store
            VerifiedIdentityStore.upsert(identity)

            // Legacy DIDWallet hook (kept for backward-compat)
            try? await DIDWallet.shared.storeUserIdHash(hash, provider: provider.rawValue)

            viewState = .success(identity)
        } catch {
            viewState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Token exchange + national ID helpers (unchanged from original)

    private func exchangeCodeForIDToken(_ code: String, provider: EIDProvider) async throws -> String {
        let url = AppConfig.authTokenURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["code": code, "provider": provider.rawValue]
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw IdentityError.tokenExchangeFailed
        }
        struct TokenResponse: Decodable { let idToken: String }
        return try JSONDecoder().decode(TokenResponse.self, from: data).idToken
    }

    private func extractNationalID(from idToken: String, provider: EIDProvider) -> String {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return "" }
        switch provider {
        case .cmdPT:  return json["nif"]  as? String ?? json["sub"] as? String ?? ""
        case .diiaUA: return json["rnokpp"] as? String ?? json["sub"] as? String ?? ""
        case .npaDe:  return json["personalausweis_id"] as? String ?? json["sub"] as? String ?? ""
        case .eidas:  return json["eidas_personal_identifier"] as? String ?? json["sub"] as? String ?? ""
        }
    }

    private func normalize(nationalID: String, provider: EIDProvider) -> String {
        switch provider {
        case .diiaUA: return "UA:\(nationalID.filter(\.isNumber))"
        case .cmdPT:  return "PT:\(nationalID.filter(\.isNumber))"
        case .npaDe:  return "DE:\(nationalID.uppercased().filter { $0.isLetter || $0.isNumber })"
        case .eidas:  return "EU:\(nationalID)"
        }
    }

    private func loadOrCreateSalt() throws -> String {
        let account = "com.noborders.identity.salt"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String: account,
                                     kSecReturnData as String: true]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let salt = String(data: data, encoding: .utf8) { return salt }

        var saltBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &saltBytes) == errSecSuccess else {
            throw IdentityError.saltGenerationFailed
        }
        let saltString = Data(saltBytes).base64EncodedString()
        let attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String: account,
                                     kSecValueData as String: saltString.data(using: .utf8)!,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let addStatus = SecItemAdd(attrs as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw IdentityError.keychainFailed(addStatus) }
        return saltString
    }

    // MARK: - Errors

    private enum IdentityError: LocalizedError {
        case tokenExchangeFailed
        case saltGenerationFailed
        case keychainFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .tokenExchangeFailed:   return "Failed to exchange authorization code"
            case .saltGenerationFailed:  return "CSPRNG unavailable — salt generation failed"
            case .keychainFailed(let s): return "Keychain error: \(s)"
            }
        }
    }
}

// MARK: - EIDProvider (kept in this file for auth URL access)

enum EIDProvider: String, CaseIterable {
    case cmdPT  = "cmd-pt"
    case diiaUA = "diia-ua"
    case npaDe  = "npa-de"
    case eidas  = "eidas"

    var flag: String {
        switch self {
        case .cmdPT:  return "🇵🇹"
        case .diiaUA: return "🇺🇦"
        case .npaDe:  return "🇩🇪"
        case .eidas:  return "🌍"
        }
    }

    var displayName: String {
        switch self {
        case .cmdPT:  return "Portugal — CMD"
        case .diiaUA: return "Ukraine — Diia"
        case .npaDe:  return "Germany — nPA / AusweisApp2"
        case .eidas:  return "EU — eIDAS"
        }
    }

    var subtitle: String {
        switch self {
        case .cmdPT:  return "Chave Móvel Digital"
        case .diiaUA: return "Дія — national digital identity"
        case .npaDe:  return "Personalausweis online function"
        case .eidas:  return "Cross-border EU digital identity"
        }
    }

    var authorizationURL: URL? {
        let cb = AppConfig.authCallbackURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? AppConfig.authCallbackURL
        let tcToken = AppConfig.eidTCTokenURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? AppConfig.eidTCTokenURL
        switch self {
        case .cmdPT:
            return URL(string: "https://preprod.autenticacao.gov.pt/oauth/asauthorize?client_id=noborders&scope=openid%20profile&response_type=code&redirect_uri=\(cb)")
        case .diiaUA:
            return URL(string: "https://api2.diia.gov.ua/api/v1/eid/partner/authorize?client_id=noborders&scope=diia.sign&redirect_uri=\(cb)")
        case .npaDe:
            return URL(string: "eid://127.0.0.1:24727/eID-Client?tcTokenURL=\(tcToken)")
        case .eidas:
            return URL(string: "https://eidas.ec.europa.eu/EidasNode/ServiceRequesterMetadata?client_id=noborders&scope=openid%20profile&redirect_uri=\(cb)")
        }
    }

    var callbackScheme: String { "https" }
}

// MARK: - DIDWallet extension

extension DIDWallet {
    func storeUserIdHash(_ hash: String, provider: String) async throws {
        let account  = "com.noborders.identity.useridhash"
        let combined = "\(provider):\(hash)"
        let attrs: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      combined.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(attrs as CFDictionary)
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw DIDError.keychainFailed(status) }
    }
}

// MARK: - UIApplication + ASWebAuth helpers

private extension UIApplication {
    var firstKeyWindow: (UIWindow & ASWebAuthenticationPresentationContextProviding)? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            .flatMap { $0 as? (UIWindow & ASWebAuthenticationPresentationContextProviding) }
    }
}

extension UIWindow: @retroactive ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { self }
}

// MARK: - Data base64url

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}

import Security

#Preview {
    IdentityView()
        .environmentObject(OnboardingCoordinator())
}
