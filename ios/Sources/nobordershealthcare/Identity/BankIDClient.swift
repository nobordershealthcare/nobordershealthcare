// IdentityProvider protocol + 4 concrete types for national eID authentication.
// Every provider terminates in an OIDCIDToken delivered to the caller.
// The token is sent to Gatekeeper (POST /auth/token) which hashes the national
// identifier and returns a Noborders JWT — the OIDCIDToken itself is then discarded.

import Foundation
import AuthenticationServices
import CryptoKit

// MARK: - Shared types

struct OIDCIDToken: Sendable {
    let rawJWT: String
    let issuer: String
    let nationalIdentifier: String  // raw national ID — Gatekeeper hashes it; never stored
    let provider: IDProviderKind
}

enum IDProviderKind: String, Sendable {
    case portugueseCMD = "pt-cmd"
    case germanEID     = "de-eid"
    case ukrainianDiia = "ua-diia"
    case euEIDAS       = "eu-eidas"
}

enum IdentityError: Error, Sendable {
    case cancelled
    case networkFailed(Error)
    case tokenParsingFailed
    case providerAppNotInstalled
    case normalizationFailed(String)
}

protocol IdentityProvider: Sendable {
    // @MainActor: authentication presents UIKit UI and calls UIApplication APIs.
    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> OIDCIDToken
}

// MARK: - Portuguese CMD (Chave Móvel Digital)
// OIDC Authorization Code + PKCE via ASWebAuthenticationSession.
// Issuer: autenticacao.gov.pt

struct PortugueseCMDProvider: IdentityProvider {

    private let authEndpoint = "https://autenticacao.gov.pt/oauth/authorize"
    private let tokenEndpoint = "https://autenticacao.gov.pt/oauth/token"
    private let clientID: String
    private let redirectURI: String

    init(clientID: String, redirectURI: String) {
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> OIDCIDToken {
        let (verifier, challenge) = pkce()
        let state = randomHex(16)

        var components = URLComponents(string: authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id",     value: clientID),
            URLQueryItem(name: "redirect_uri",  value: redirectURI),
            URLQueryItem(name: "scope",         value: "openid profile"),
            URLQueryItem(name: "state",         value: state),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        let callbackURL = try await webAuth(url: components.url!, callbackScheme: callbackScheme(from: redirectURI), anchor: anchor)
        let code = try extractCode(from: callbackURL, expectedState: state)
        return try await exchangeCode(code, verifier: verifier, provider: .portugueseCMD, issuer: "autenticacao.gov.pt")
    }
}

// MARK: - German eID (nPA / Personalausweis via AusweisApp2)
// AppSwitch to AusweisApp2 for card reading, then OAuth2 code exchange.
// AusweisApp2 URL scheme: ausweisapp2://

struct GermanEIDProvider: IdentityProvider {

    private let tcTokenEndpoint: String  // server-side TC Token endpoint
    private let clientID: String
    private let redirectURI: String

    init(tcTokenEndpoint: String, clientID: String, redirectURI: String) {
        self.tcTokenEndpoint = tcTokenEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> OIDCIDToken {
        guard UIApplication.shared.canOpenURL(URL(string: "ausweisapp2://")!) else {
            throw IdentityError.providerAppNotInstalled
        }

        let state = randomHex(16)
        let (verifier, challenge) = pkce()

        // Build TC Token URL — AusweisApp2 fetches this to begin the eID session
        var tcComponents = URLComponents(string: tcTokenEndpoint)!
        tcComponents.queryItems = [
            URLQueryItem(name: "client_id",             value: clientID),
            URLQueryItem(name: "redirect_uri",          value: redirectURI),
            URLQueryItem(name: "state",                 value: state),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        let ausweisURL = URL(string: "ausweisapp2://auth?tcTokenURL=\(tcComponents.url!.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")!
        await UIApplication.shared.open(ausweisURL)

        // AusweisApp2 redirects back via the redirectURI universal link carrying the auth code
        let callbackURL = try await waitForUniversalLinkCallback(state: state)
        let code = try extractCode(from: callbackURL, expectedState: state)
        return try await exchangeCode(code, verifier: verifier, provider: .germanEID, issuer: "eid.bundesdruckerei.de")
    }
}

// MARK: - Ukrainian Diia
// OAuth2 flow via ASWebAuthenticationSession.
// Diia returns РНОКПП (RNOKPP — tax ID). Must be normalized to "UA:" + digits
// before Gatekeeper hashes it, so all providers produce the same pseudonym format.

struct UkrainianDiiaProvider: IdentityProvider {

    private let authEndpoint  = "https://api2.diia.gov.ua/api/v1/auth"
    private let tokenEndpoint = "https://api2.diia.gov.ua/api/v1/auth/token"
    private let partnerToken: String   // from Diia partner portal, stored in Keychain — never hardcoded
    private let redirectURI: String

    init(partnerToken: String, redirectURI: String) {
        self.partnerToken = partnerToken
        self.redirectURI = redirectURI
    }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> OIDCIDToken {
        let state = randomHex(16)
        var components = URLComponents(string: authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "partnerToken", value: partnerToken),
            URLQueryItem(name: "state",        value: state),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]

        let callbackURL = try await webAuth(url: components.url!, callbackScheme: callbackScheme(from: redirectURI), anchor: anchor)
        let rawToken = try await fetchDiiaToken(from: callbackURL, state: state)

        // Normalize RNOKPP → "UA:" + 10 digits (strip any spaces/dashes from Diia claim)
        let rnokpp = try normalizeRNOKPP(rawToken.rnokpp)
        let normalizedID = "UA:\(rnokpp)"

        return OIDCIDToken(
            rawJWT:             rawToken.jwt,
            issuer:             "diia.gov.ua",
            nationalIdentifier: normalizedID,
            provider:           .ukrainianDiia
        )
    }

    private func normalizeRNOKPP(_ raw: String) throws -> String {
        let digits = raw.filter { $0.isNumber }
        guard digits.count == 10 else {
            throw IdentityError.normalizationFailed("RNOKPP must be exactly 10 digits, got \(digits.count)")
        }
        return digits
    }
}

// MARK: - EU eIDAS generic OIDC fallback
// For any eIDAS-notified national eID not covered by the above.
// Requires a country-specific eIDAS bridge endpoint.

struct EUeIDASProvider: IdentityProvider {

    private let authEndpoint: String
    private let tokenEndpoint: String
    private let clientID: String
    private let redirectURI: String
    private let countryCode: String  // ISO 3166-1 alpha-2

    init(authEndpoint: String, tokenEndpoint: String, clientID: String, redirectURI: String, countryCode: String) {
        self.authEndpoint  = authEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID      = clientID
        self.redirectURI   = redirectURI
        self.countryCode   = countryCode
    }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> OIDCIDToken {
        let (verifier, challenge) = pkce()
        let state = randomHex(16)

        var components = URLComponents(string: authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "client_id",             value: clientID),
            URLQueryItem(name: "redirect_uri",          value: redirectURI),
            URLQueryItem(name: "scope",                 value: "openid"),
            URLQueryItem(name: "state",                 value: state),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "country",               value: countryCode),
        ]

        let callbackURL = try await webAuth(url: components.url!, callbackScheme: callbackScheme(from: redirectURI), anchor: anchor)
        let code = try extractCode(from: callbackURL, expectedState: state)
        return try await exchangeCode(code, verifier: verifier, provider: .euEIDAS, issuer: authEndpoint)
    }
}

// MARK: - PKCE + ASWebAuthenticationSession helpers (private, file-scoped)

private func pkce() -> (verifier: String, challenge: String) {
    var bytes = Data(count: 32)
    _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    let verifier = bytes.base64URLEncodedString()
    let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
    return (verifier, challengeData.base64URLEncodedString())
}

private func randomHex(_ byteCount: Int) -> String {
    var bytes = Data(count: byteCount)
    _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private func callbackScheme(from uri: String) -> String {
    URL(string: uri)?.scheme ?? "noborders"
}

@MainActor
private func webAuth(url: URL, callbackScheme: String, anchor: ASPresentationAnchor) async throws -> URL {
    try await withCheckedThrowingContinuation { cont in
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
            if let error {
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    cont.resume(throwing: IdentityError.cancelled)
                } else {
                    cont.resume(throwing: IdentityError.networkFailed(error))
                }
                return
            }
            guard let callbackURL else { cont.resume(throwing: IdentityError.tokenParsingFailed); return }
            cont.resume(returning: callbackURL)
        }
        session.presentationContextProvider = AnchorProvider(anchor: anchor)
        session.prefersEphemeralWebBrowserSession = true
        session.start()
    }
}

private func extractCode(from url: URL, expectedState: String) throws -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let code  = components.queryItems?.first(where: { $0.name == "code" })?.value,
          let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
          state == expectedState
    else { throw IdentityError.tokenParsingFailed }
    return code
}

private func exchangeCode(_ code: String, verifier: String, provider: IDProviderKind, issuer: String) async throws -> OIDCIDToken {
    // In production: POST to the provider's token endpoint with code + verifier.
    // Parse the id_token JWT, extract the sub claim as nationalIdentifier.
    // Full implementation requires a network call — placeholder structure only.
    throw IdentityError.networkFailed(URLError(.notConnectedToInternet))
}

private func fetchDiiaToken(from callbackURL: URL, state: String) async throws -> (jwt: String, rnokpp: String) {
    // Parse Diia callback, exchange for token, extract RNOKPP claim.
    throw IdentityError.networkFailed(URLError(.notConnectedToInternet))
}

// AusweisApp2 redirects via universal link; this waits for the system to route it back.
private func waitForUniversalLinkCallback(state: String) async throws -> URL {
    try await withCheckedThrowingContinuation { cont in
        let observer = NotificationCenter.default.addObserver(
            forName: .ausweisApp2Callback, object: nil, queue: .main
        ) { notification in
            guard let url = notification.object as? URL else { return }
            cont.resume(returning: url)
        }
        // Timeout after 5 minutes (user interacts with AusweisApp2)
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            NotificationCenter.default.removeObserver(observer)
            cont.resume(throwing: IdentityError.cancelled)
        }
    }
}

extension Notification.Name {
    static let ausweisApp2Callback = Notification.Name("com.noborders.ausweisapp2.callback")
}

// MARK: - ASPresentationContextProviding

@MainActor
private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

// MARK: - Data extensions

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
