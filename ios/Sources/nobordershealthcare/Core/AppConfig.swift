// AppConfig.swift — Single source of truth for all service endpoints on iOS.
//
// ABSOLUTE RULE: NO URL string literals for internal or own-domain endpoints
// anywhere in the codebase. All service URLs come from this file, which reads
// from Info.plist build variables injected at compile time via project.yml.
//
// How to add a new endpoint:
//   1. Add a build setting to project.yml (base + Debug/Release overrides)
//   2. Inject it into Info.plist: KEY: $(KEY)
//   3. Add a static computed property here
//   4. Use AppConfig.myNewURL in the call site — NEVER a string literal
//
// Swift:  AppConfig.apiBaseURL.appendingPathComponent("/auth/token")
// DO NOT: URL(string: "https://api.nobords.healthcare/auth/token")
//
// Debug build settings (project.yml → configs.Debug):
//   API_BASE_URL:       http://localhost:8080
//   APP_BASE_URL:       http://localhost:3000
//   PHYSICIAN_VIEW_URL: http://localhost:8083
//
// Release build settings:
//   API_BASE_URL:       https://api.noborders.healthcare
//   APP_BASE_URL:       https://app.noborders.health
//   PHYSICIAN_VIEW_URL: https://scan.noborders.healthcare

import Foundation

enum AppConfig {

    // MARK: - Info.plist key names (must match project.yml)

    private static let keyAPIBase       = "API_BASE_URL"
    private static let keyAppBase       = "APP_BASE_URL"
    private static let keyPhysicianView = "PHYSICIAN_VIEW_URL"

    // MARK: - Service base URLs

    /// API gateway: https://api.noborders.healthcare (Release) / http://localhost:8080 (Debug)
    /// Used for: auth/token, auth/revoke, activate/validate, FHIR endpoints
    static let apiBaseURL: URL = url(forKey: keyAPIBase,
                                     fallback: "https://api.noborders.healthcare")

    /// App web base: https://app.noborders.health (Release) / http://localhost:3000 (Debug)
    /// Used for: deep links (auth/callback, activate/{token}), proxy share links
    static let appBaseURL: URL = url(forKey: keyAppBase,
                                     fallback: "https://app.noborders.health")

    /// App host for deep-link matching in onOpenURL
    static let appHost: String = appBaseURL.host ?? "app.noborders.health"

    /// Physician-view (emergency QR scan): https://scan.noborders.healthcare (Release)
    static let physicianViewURL: URL = url(forKey: keyPhysicianView,
                                           fallback: "https://scan.noborders.healthcare")

    // MARK: - Derived endpoint URLs

    /// POST /auth/token — exchange eID authorization code for ID token
    static let authTokenURL: URL    = apiBaseURL.appendingPathComponent("/auth/token")

    /// POST /auth/revoke — invalidate an emergency JWT (jti)
    static let authRevokeURL: URL   = apiBaseURL.appendingPathComponent("/auth/revoke")

    /// POST /activate/validate — validate a bulk-import activation token
    static let activateValidateURL: URL = apiBaseURL.appendingPathComponent("/activate/validate")

    /// GET/POST /auth/callback — OAuth redirect_uri for eID providers
    static let authCallbackURL: String  = appBaseURL.appendingPathComponent("/auth/callback").absoluteString

    /// GET /eid/tc-token — AusweisApp2 tcTokenURL for German nPA
    static let eidTCTokenURL: String    = appBaseURL.appendingPathComponent("/eid/tc-token").absoluteString

    // MARK: - Private helper

    /// Reads a URL from Info.plist; crashes at startup (not at call site) if
    /// the value is present but not a valid URL.
    private static func url(forKey key: String, fallback: String) -> URL {
        let raw = Bundle.main.infoDictionary?[key] as? String ?? fallback
        guard let u = URL(string: raw) else {
            // Fatal — a misconfigured build setting should crash immediately,
            // not produce a silent nil that causes confusing failures later.
            fatalError("AppConfig: '\(key)' = '\(raw)' is not a valid URL")
        }
        return u
    }
}
