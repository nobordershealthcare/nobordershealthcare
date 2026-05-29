// DiiaIdentityPayload.swift — Identity payload returned by the Дія (Diia) backend.
//
// The backend verifies the Diia JWT, extracts identity claims, computes
// SHA3-256(salt + "UA:" + РНОКПП), and returns only the hash and a
// pre-masked display string.  The raw РНОКПП never reaches the iOS client.
//
// Security properties:
//   • rnokppHash   — pre-computed by the backend; stored directly in vault
//   • rnokppMasked — display-only "••••••7890"; never stored
//   • firstName / patronymic / lastName — display-only; never stored or logged

import Foundation

// MARK: - DiiaIdentityPayload

struct DiiaIdentityPayload: Codable, Sendable, Equatable {

    // ── Identity claims ─────────────────────────────────────────────────────

    /// Ім'я — given name as registered in the State Register of Civil Status
    let firstName: String

    /// По батькові — patronymic (empty string if absent in the Diia document)
    let patronymic: String

    /// Прізвище — family name
    let lastName: String

    /// Pre-masked РНОКПП for display: "••••••7890"
    /// Show as-is — no client-side masking or transformation.
    let rnokppMasked: String

    /// SHA3-256(salt + "UA:" + РНОКПП), hex — computed by the backend.
    /// This is the only РНОКПП-derived value stored in the vault;
    /// the raw РНОКПП never arrives on the iOS client.
    let rnokppHash: String

    /// requestId — echo of the UUID sent in the auth request (replay protection)
    let requestId: String

    // MARK: - Derived (display only)

    /// Full display name in Ukrainian natural order: Прізвище Ім'я По батькові
    var fullName: String {
        [lastName, firstName, patronymic]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Stub fixture (DEBUG only)

    // H-02: stub() is excluded from Release builds so that jailbroken devices
    // cannot call DiiaService.shared.state = .received(.stub()) to bypass real
    // identity verification. The #if DEBUG guard is compile-time, not runtime.
    #if DEBUG
    /// Deterministic test fixture for simulator or stub mode testing.
    /// Named after Тарас Григорович Шевченко — Ukrainian national poet.
    /// rnokppHash is a fixed SHA3-256 sentinel value used only in tests.
    static func stub(requestId: String = "stub-\(UUID().uuidString)") -> DiiaIdentityPayload {
        DiiaIdentityPayload(
            firstName:    "Тарас",
            patronymic:   "Григорович",
            lastName:     "Шевченко",
            rnokppMasked: "••••••7890",
            rnokppHash:   "530e24b85d45d7c03dbf62757d92ce3b9c6f09cf4843e239c6eec5f05b7f4291",
            requestId:    requestId
        )
    }
    #endif
}
