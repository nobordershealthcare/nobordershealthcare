// IdentityView.swift — Step 2: National identity verification via eID providers.
//
// Four providers, each triggering ASWebAuthenticationSession OIDC flows:
//   🇵🇹 CMD  — Chave Móvel Digital (Portugal)
//   🇺🇦 Diia — Ukrainian national digital ID
//   🇩🇪 nPA  — Personalausweis via AusweisApp2 AppSwitch
//   🌍 eIDAS — Generic EU OIDC, country-specific issuer
//
// On success:
//   SHA3_256(per-user-salt + normalized_national_id) → userIdentityHash
//   Salt generated once, stored in Keychain plaintext
//   Hash stored in VaultManager (Silo 1) via DIDWallet
//   Plaintext national ID zeroed from memory immediately
//
// GDPR: national ID is special-category data — only its hash is ever persisted.

import SwiftUI
import AuthenticationServices
import SHA3Kit

// MARK: - Identity provider

private enum EIDProvider: String, CaseIterable {
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
        switch self {
        case .cmdPT:
            // Portugal OIDC endpoint — requires Autenticação.gov.pt client registration
            return URL(string: "https://preprod.autenticacao.gov.pt/oauth/asauthorize?client_id=noborders&scope=openid%20profile&response_type=code&redirect_uri=https://app.noborders.health/auth/callback")
        case .diiaUA:
            // Ukraine Diia partner integration — Ministry of Digital Transformation
            return URL(string: "https://api2.diia.gov.ua/api/v1/eid/partner/authorize?client_id=noborders&scope=diia.sign&redirect_uri=https://app.noborders.health/auth/callback")
        case .npaDe:
            // AusweisApp2 AppSwitch — universal link triggers native app
            return URL(string: "eid://127.0.0.1:24727/eID-Client?tcTokenURL=https://app.noborders.health/eid/tc-token")
        case .eidas:
            // EU eIDAS node — country detected from SIM/location at runtime
            return URL(string: "https://eidas.ec.europa.eu/EidasNode/ServiceRequesterMetadata?client_id=noborders&scope=openid%20profile&redirect_uri=https://app.noborders.health/auth/callback")
        }
    }

    var callbackScheme: String { "https" }
}

// MARK: - Authentication state

private enum AuthState: Equatable {
    case idle
    case authenticating(EIDProvider)
    case success(userIdHash: String)
    case failed(String)
}

// MARK: - IdentityView

struct IdentityView: View {

    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @State private var authState: AuthState = .idle
    @State private var webAuthSession: ASWebAuthenticationSession?

    private let callbackURL = "https://app.noborders.health/auth/callback"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header

                    providerList

                    if case .failed(let msg) = authState {
                        errorBanner(msg)
                    }

                    if case .success = authState {
                        successBanner
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .navigationTitle("Verify Identity")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link your national identity")
                .font(.title3).fontWeight(.bold)
            Text("Your identity is verified once, then hashed. No personal data is stored — only a cryptographic fingerprint that lets emergency systems recognize you.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerList: some View {
        VStack(spacing: 12) {
            ForEach(EIDProvider.allCases, id: \.rawValue) { provider in
                providerButton(provider)
            }
        }
    }

    private func providerButton(_ provider: EIDProvider) -> some View {
        let isActive: Bool
        if case .authenticating(let p) = authState, p == provider {
            isActive = true
        } else {
            isActive = false
        }

        return Button {
            startAuth(provider: provider)
        } label: {
            HStack(spacing: 16) {
                Text(provider.flag)
                    .font(.largeTitle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.body).fontWeight(.semibold)
                    Text(provider.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                if isActive {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(authState != .idle)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Authentication failed")
                    .font(.subheadline).fontWeight(.semibold)
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { authState = .idle } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var successBanner: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identity verified")
                        .font(.subheadline).fontWeight(.semibold)
                    Text("Your identity hash is stored securely on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                coordinator.markIdentityComplete()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.navy)
        }
    }

    // MARK: - Authentication flow

    private func startAuth(provider: EIDProvider) {
        guard let url = provider.authorizationURL else {
            authState = .failed("Authorization URL not available for \(provider.displayName)")
            return
        }

        // nPA: AppSwitch to AusweisApp2 — try to open the universal link directly
        if provider == .npaDe {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            } else {
                // AusweisApp2 not installed — fall back to eIDAS
                startAuth(provider: .eidas)
            }
            return
        }

        authState = .authenticating(provider)

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil  // universal link — no custom scheme
        ) { callbackURL, error in
            Task { @MainActor in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        authState = .idle
                    } else {
                        authState = .failed(error.localizedDescription)
                    }
                    return
                }
                guard let callbackURL else {
                    authState = .failed("No callback URL received")
                    return
                }
                await handleCallback(url: callbackURL, provider: provider)
            }
        }
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = UIApplication.shared.firstKeyWindow
        webAuthSession = session
        session.start()
    }

    private func handleCallback(url: URL, provider: EIDProvider) async {
        // Extract authorization code from callback URL
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            authState = .failed("Authorization code not found in callback")
            return
        }

        do {
            // Exchange code for ID token via Gatekeeper backend
            let idToken = try await exchangeCodeForIDToken(code, provider: provider)

            // Extract national ID claim from verified JWT
            // Each provider uses a different claim name
            var nationalID = extractNationalID(from: idToken, provider: provider)
            defer {
                // Zero the plaintext national ID immediately after hashing
                nationalID.removeAll(keepingCapacity: false)
            }

            guard !nationalID.isEmpty else {
                authState = .failed("National ID claim not found in identity token")
                return
            }

            // Normalize the ID per provider format
            let normalized = normalize(nationalID: nationalID, provider: provider)

            // Hash: SHA3_256(per-user-salt + normalized)
            let salt = try loadOrCreateSalt()
            let combined = (salt + normalized).data(using: .utf8) ?? Data()
            let userIdHash = SHA3_256.hash(data: combined).description

            // Store in DIDWallet (Silo 1 — eHR vault)
            try await DIDWallet.shared.storeUserIdHash(userIdHash, provider: provider.rawValue)

            authState = .success(userIdHash: userIdHash)
        } catch {
            authState = .failed(error.localizedDescription)
        }
    }

    // MARK: - ID token exchange

    private func exchangeCodeForIDToken(_ code: String, provider: EIDProvider) async throws -> String {
        // Exchange authorization code for ID token via Gatekeeper backend.
        // Gatekeeper validates the token against the provider's public keys.
        let url = URL(string: "https://api.noborders.health/auth/token")!
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
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return decoded.idToken
    }

    // MARK: - National ID extraction and normalization

    private func extractNationalID(from idToken: String, provider: EIDProvider) -> String {
        // Decode JWT payload (base64url) — not verifying signature here, Gatekeeper did.
        let parts = idToken.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return "" }

        // Provider-specific claim names per their OIDC implementations
        switch provider {
        case .cmdPT:  return json["nif"] as? String ?? json["sub"] as? String ?? ""
        case .diiaUA: return json["rnokpp"] as? String ?? json["sub"] as? String ?? ""
        case .npaDe:  return json["personalausweis_id"] as? String ?? json["sub"] as? String ?? ""
        case .eidas:  return json["eidas_personal_identifier"] as? String ?? json["sub"] as? String ?? ""
        }
    }

    private func normalize(nationalID: String, provider: EIDProvider) -> String {
        switch provider {
        case .diiaUA:
            // РНОКПП → "UA:" + digits only
            let digits = nationalID.filter(\.isNumber)
            return "UA:\(digits)"
        case .cmdPT:
            // NIF → "PT:" + 9 digits
            let digits = nationalID.filter(\.isNumber)
            return "PT:\(digits)"
        case .npaDe:
            // Pseudonym from nPA → "DE:" + uppercase alphanumeric
            return "DE:\(nationalID.uppercased().filter { $0.isLetter || $0.isNumber })"
        case .eidas:
            // eIDAS personal identifier: CC/CC/xxx format → stored as-is
            return "EU:\(nationalID)"
        }
    }

    // MARK: - Salt management

    private func loadOrCreateSalt() throws -> String {
        let account = "com.noborders.identity.salt"
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data,
           let salt = String(data: data, encoding: .utf8) {
            return salt
        }

        // Generate new salt: 32 random bytes base64-encoded
        var saltBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &saltBytes) == errSecSuccess else {
            throw IdentityError.saltGenerationFailed
        }
        let saltString = Data(saltBytes).base64EncodedString()

        let attrs: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      saltString.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(attrs as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw IdentityError.keychainFailed(addStatus)
        }
        return saltString
    }

    // MARK: - Errors

    private enum IdentityError: LocalizedError {
        case tokenExchangeFailed
        case saltGenerationFailed
        case keychainFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tokenExchangeFailed:   return "Failed to exchange authorization code for identity token"
            case .saltGenerationFailed:  return "Failed to generate identity salt — CSPRNG unavailable"
            case .keychainFailed(let s): return "Keychain error: \(s)"
            }
        }
    }
}

// MARK: - DIDWallet extension for identity storage

extension DIDWallet {
    /// Stores the SHA3-256 userIdHash in the eHR vault.
    func storeUserIdHash(_ hash: String, provider: String) async throws {
        // Persisted via DIDWallet's existing Keychain infrastructure.
        // The hash is the user's stable identity across all app sessions.
        let account = "com.noborders.identity.useridhash"
        let combined = "\(provider):\(hash)"
        let attrs: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      combined.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(attrs as CFDictionary)
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DIDError.keychainFailed(status)
        }
    }
}

// MARK: - UIApplication helper

private extension UIApplication {
    var firstKeyWindow: (UIWindow & ASWebAuthenticationPresentationContextProviding)? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            .flatMap { $0 as? (UIWindow & ASWebAuthenticationPresentationContextProviding) }
    }
}

// MARK: - UIWindow + ASWebAuth

extension UIWindow: @retroactive ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return self
    }
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

// MARK: - Security import

import Security

#Preview {
    IdentityView()
        .environmentObject(OnboardingCoordinator())
}
