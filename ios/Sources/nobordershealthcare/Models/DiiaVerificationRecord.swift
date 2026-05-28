// DiiaVerificationRecord.swift — Permanent record of a completed Дія identity verification.
//
// STORAGE: IdentityVaultManager (Silo 1), key: .diiaVerification
// AES-256-GCM encrypted + SE-bound key; biometric auth required to read.
//
// PRIVACY RULES:
//   rnokppHash: SHA3-256 hex — ONLY this is stored, never plaintext РНОКПП.
//   firstName / lastName: plaintext OK (needed for UI display after verification).
//   patronymic: optional, plaintext.
//   NEVER log firstName + lastName + patronymic together.
//   Log correlation key: SHA3_256(firstName + lastName).prefix(8)

import Foundation

struct DiiaVerificationRecord: Codable, Sendable, Identifiable {
    var id:           UUID    = UUID()

    // Identity fields — stored plaintext for UI display.
    // NEVER log all three together (see V-07).
    var firstName:    String
    var patronymic:   String?
    var lastName:     String

    /// "••••••7890" — display only, never log
    var rnokppMasked: String

    /// SHA3-256(salt + rnokpp) hex — computed by backend, stored here
    var rnokppHash:   String

    /// Backend-assigned ID for this auth session
    var requestId:    String

    /// Time the verification was accepted and committed
    var verifiedAt:   Date

    /// ISO 3166-1 alpha-2 country code (always "UA" for Diia)
    var countryCode:  String = "UA"
}
