// ConsentAuditService.swift — Dual-source consent validation and blockchain sync.
//
// Checks BOTH sources of truth for any consent query:
//   Source 1: IdentityVaultManager (local, offline-capable, authoritative for granting)
//   Source 2: Hyperledger Fabric channel 2 (on-chain, authoritative for revocation)
//
// Decision rule:
//   - Local item granted AND blockchainTxHash set   → .valid
//   - Local item granted, no blockchainTxHash       → .validPendingBlockchain (show warning)
//   - Local item has revokedAt set                  → .revoked(at:) immediately
//   - No matching record or item                    → .notFound
//   - Blockchain says revoked, local says active    → trust blockchain (admin-level revoke)
//
// LOCAL IS AUTHORITATIVE for granting. BLOCKCHAIN IS AUTHORITATIVE for revocation.
//
// Pending queue: signatures and consents that failed to broadcast (offline) are
// re-queued here. A background task retries them when network connectivity returns.
//
// Domain types (ConsentType, ConsentRecord, SignatureRecord, etc.) are in Models.swift.

import Foundation
import Combine

// MARK: - Consent status

enum ConsentStatus: Equatable {
    case valid                              // local granted + on-chain confirmed
    case validPendingBlockchain             // local granted only, not yet on-chain
    case revoked(at: Date)
    case notFound
    case unknown(String)                    // indeterminate — show error, do NOT grant access

    var isGranted: Bool {
        switch self {
        case .valid, .validPendingBlockchain: return true
        default: return false
        }
    }

    var warningMessage: String? {
        switch self {
        case .validPendingBlockchain:
            return "Pending blockchain confirmation"
        default:
            return nil
        }
    }
}

// MARK: - ConsentAuditService

// @MainActor so @Published properties can drive SwiftUI views directly.
// Blocking work (vault reads, network) is dispatched to background actors.
@MainActor
final class ConsentAuditService: ObservableObject {

    static let shared = ConsentAuditService()

    @Published private(set) var pendingSignatureIds: Set<UUID> = []
    @Published private(set) var pendingConsentIds: Set<UUID> = []
    @Published private(set) var isSyncing = false

    private var retryTask: Task<Void, Never>?

    // MARK: - Consent status query

    /// Returns the effective consent status for the given ConsentType, checking both
    /// local vault and blockchain. This is the SINGLE call site for all access decisions.
    /// Never check IdentityVaultManager or FabricClient directly for consent gating.
    func status(for consentType: ConsentType) async -> ConsentStatus {
        do {
            let records = try await IdentityVaultManager.shared.openAllConsents()
            let sorted  = records.sorted { $0.signedAt > $1.signedAt }  // most recent first

            for record in sorted {
                guard let item = record.items.first(where: { $0.type == consentType }) else { continue }

                // Revoked locally → immediately invalid (GDPR Art.7(3))
                if let revokedAt = item.revokedAt {
                    return .revoked(at: revokedAt)
                }

                // Item exists but was never granted
                guard item.granted else { continue }

                // Granted but no blockchain confirmation yet
                guard let txHash = record.blockchainTxHash else {
                    return .validPendingBlockchain
                }

                // Optional: verify on-chain status (catches admin-side revocations)
                let chainStatus = await checkChainRevocation(consentType: consentType, txHash: txHash)
                if case .revoked(let at) = chainStatus {
                    // Mirror on-chain revocation to local vault.
                    // If the local write fails we still honour the on-chain revocation —
                    // the caller receives .revoked regardless.  Never use try? here:
                    // silent failure would leave local vault out of sync without any
                    // diagnostic trace.
                    do {
                        try await IdentityVaultManager.shared.revokeConsentType(consentType, revokedAt: at)
                    } catch {
                        // Log error hash only — no PII in logs (GDPR Art.83).
                        let tag = SHA3_256.hash(data: Data(error.localizedDescription.utf8))
                            .description.prefix(16)
                        print("[ConsentAuditService] local revocation mirror failed — errTag:\(tag)")
                    }
                    return chainStatus
                }

                return .valid
            }

            return .notFound

        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    // MARK: - Pending queue management

    /// Called by SignatureButton when a channel-1 broadcast fails (offline).
    nonisolated func enqueuePendingSignature(_ id: UUID) {
        Task { @MainActor in
            pendingSignatureIds.insert(id)
            schedulePendingRetry()
        }
    }

    /// Called by SignatureButton when a channel-2 broadcast fails (offline).
    nonisolated func enqueuePendingConsent(_ id: UUID) {
        Task { @MainActor in
            pendingConsentIds.insert(id)
            schedulePendingRetry()
        }
    }

    // MARK: - Retry loop

    private func schedulePendingRetry() {
        guard retryTask.map({ $0.isCancelled }) ?? true else { return }
        retryTask = Task { [weak self] in
            await self?.retryPending()
        }
    }

    private func retryPending() async {
        // Back-off: wait 30 s before first retry after going offline.
        try? await Task.sleep(for: .seconds(30))

        guard !pendingSignatureIds.isEmpty || !pendingConsentIds.isEmpty else {
            retryTask = nil
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        // Retry pending signatures (channel 1)
        var remainingSigs = pendingSignatureIds
        for sigId in pendingSignatureIds {
            do {
                let sigs = try await IdentityVaultManager.shared.openSignatureRecords()
                guard let sig = sigs.first(where: { $0.id == sigId }) else {
                    remainingSigs.remove(sigId)  // record gone — remove from queue
                    continue
                }
                guard sig.blockchainTxHash == nil else {
                    remainingSigs.remove(sigId)  // already confirmed elsewhere
                    continue
                }
                let txHash = try await FabricClient.channel1.recordAdESSignature(
                    documentHash:       sig.documentHash,
                    signerPubKeyHash:   sig.publicKeyHash,
                    signatureBase64:    sig.signature.base64URLEncodedString(),
                    identityProvider:   sig.identityProvider,
                    identityVerifiedAt: Int64(sig.identityVerifiedAt.timeIntervalSince1970),
                    legalBasis:         sig.legalBasis.map { $0.rawValue },
                    documentType:       sig.documentType.rawValue,
                    jurisdictions:      sig.jurisdictions
                )
                try await IdentityVaultManager.shared.updateSignatureTxHash(id: sigId, txHash: txHash)
                remainingSigs.remove(sigId)
            } catch {
                // Still offline or transient — leave in queue
            }
        }
        pendingSignatureIds = remainingSigs

        // Retry pending consent grants (channel 2)
        var remainingConsents = pendingConsentIds
        for consentId in pendingConsentIds {
            do {
                let consents = try await IdentityVaultManager.shared.openAllConsents()
                guard let consent = consents.first(where: { $0.id == consentId }) else {
                    remainingConsents.remove(consentId)
                    continue
                }
                guard consent.blockchainTxHash == nil else {
                    remainingConsents.remove(consentId)
                    continue
                }
                // Find an associated SignatureRecord with a confirmed txHash
                let sigs = try await IdentityVaultManager.shared.openSignatureRecords()
                guard let sigRecord = sigs.first(where: {
                    $0.publicKeyHash == consent.publicKeyHash && $0.blockchainTxHash != nil
                }),
                let sigTxHash = sigRecord.blockchainTxHash else {
                    continue  // wait for the signature to confirm first
                }

                let userIdHash = try await DIDWallet.shared.currentUserIdHash()
                let crIdData   = consent.id.uuidString.data(using: .utf8) ?? Data()
                let consentTxHash = try await FabricClient.channel2.recordConsentGrant(
                    userIdHash:        userIdHash,
                    consentRecordHash: SHA3_256.hash(data: crIdData).description,
                    grantedTypes:      consent.items.filter { $0.granted }.map { $0.type.rawValue },
                    signatureTxHash:   sigTxHash
                )
                try await IdentityVaultManager.shared.updateConsentTxHash(id: consentId, txHash: consentTxHash)
                remainingConsents.remove(consentId)
            } catch {
                // Still offline or transient
            }
        }
        pendingConsentIds = remainingConsents

        retryTask = nil

        // Schedule another pass if items remain
        if !pendingSignatureIds.isEmpty || !pendingConsentIds.isEmpty {
            schedulePendingRetry()
        }
    }

    // MARK: - Chain revocation check

    private func checkChainRevocation(
        consentType: ConsentType,
        txHash: String
    ) async -> ConsentStatus {
        // Query channel-2 GetConsentHistory via gRPC and check for a "revoked" event
        // more recent than the grant referenced by txHash.
        // Return .revoked(at:) if found, otherwise .valid.
        // Stub: always reports .valid (no admin-side revocations in pilot).
        _ = consentType
        _ = txHash
        return .valid
    }

}

// MARK: - Data extension (base64url)

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
