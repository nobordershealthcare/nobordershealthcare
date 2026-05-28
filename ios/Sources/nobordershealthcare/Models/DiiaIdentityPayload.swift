// DiiaIdentityPayload.swift — Data returned by the Дія (Diia) App Switch.
//
// Diia sends identity claims either in a JWT callback URL or via a partner
// API response.  This struct mirrors the JSON payload in both cases.
//
// Security note: signature verification is the backend's responsibility.
// The iOS client only decodes the payload for display — it NEVER persists
// the plaintext fields.  Only SHA3-256(salt + РНОКПП) enters the vault.
//
// Stub mode: DiiaIdentityPayload.stub(requestId:) provides a deterministic
// test fixture (Тарас Григорович Шевченко) for simulator development until
// the real Diia partner integration is ready.

import Foundation

// MARK: - DiiaIdentityPayload

struct DiiaIdentityPayload: Codable, Sendable, Equatable {

    // ── Identity claims ─────────────────────────────────────────────────────
    /// Ім'я — given name as registered in the State Register of Civil Status
    let firstName: String

    /// По батькові — patronymic (optional in some Diia versions, empty string if absent)
    let patronymic: String

    /// Прізвище — family name
    let lastName: String

    /// РНОКПП — Реєстраційний номер облікової картки платника податків (10 digits)
    /// NEVER persisted — only its SHA3-256 hash enters the vault.
    let rnokpp: String

    /// requestId — echo of the UUID sent in the deep link; used to bind this
    /// response to the specific authorization request (replay protection).
    let requestId: String

    // MARK: - Derived helpers (display only)

    /// Full display name in Ukrainian natural order: Прізвище Ім'я По батькові
    var fullName: String {
        [lastName, firstName, patronymic]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// РНОКПП with middle 6 digits masked: ••••••XXXX
    /// The last 4 digits are always visible; the rest are hidden by default.
    func maskedRNOKPP(revealed: Bool) -> String {
        guard rnokpp.count == 10, !revealed else { return rnokpp }
        let last4 = String(rnokpp.suffix(4))
        return "••••••\(last4)"
    }

    // MARK: - CodingKeys (maps Diia JSON snake_case ↔ Swift camelCase)

    private enum CodingKeys: String, CodingKey {
        case firstName  = "firstName"
        case patronymic = "patronymic"
        case lastName   = "lastName"
        case rnokpp     = "rnokpp"
        case requestId  = "requestId"
    }

    // MARK: - Stub fixture

    /// Deterministic test fixture for simulator / stub mode.
    /// Named after Тарас Григорович Шевченко — Ukrainian national poet.
    static func stub(requestId: String = "stub-\(UUID().uuidString)") -> DiiaIdentityPayload {
        DiiaIdentityPayload(
            firstName:  "Тарас",
            patronymic: "Григорович",
            lastName:   "Шевченко",
            rnokpp:     "1234567890",
            requestId:  requestId
        )
    }
}
