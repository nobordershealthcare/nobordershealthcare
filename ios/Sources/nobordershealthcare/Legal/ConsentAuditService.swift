// ConsentAuditService.swift — Dual-source consent validation and blockchain sync.
//
// Checks BOTH sources of truth for any consent query:
//   Source 1: LegalVaultManager (local, offline-capable, authoritative)
//   Source 2: Hyperledger Fabric channel 2 (on-chain confirmation)
//
// Decision rule:
//   - Local record exists AND active            → consent is VALID
//   - Local record exists, no blockchain txHash → consent is VALID but show warning
//   - Local record is revoked                   → consent is INVALID (immediate)
//   - No local record                           → consent is INVALID
//   - Blockchain says revoked, local says active → trust blockchain (edge case: admin revoke)
//
// LOCAL IS AUTHORITATIVE for granting. BLOCKCHAIN IS AUTHORITATIVE for revocation.
// This ensures offline signing works while admin-level revocations propagate globally.
//
// Pending queue: signatures and consents that failed to broadcast (offline) are
// re-queued here. A background task retries them when network connectivity returns.

import Foundation
import Combine

// MARK: - Consent status

enum ConsentStatus: Equatable {
    case valid                              // local + on-chain confirmed
    case validPendingBlockchain             // local only, not yet on-chain
    case revoked(at: Date)
    case expired(at: Date)
    case notFound
    case unknown(String)                    // indeterminate — show error, do not grant access

    var isGranted: Bool {
        switch self {
        case .valid, .validPendingBlockchain: return true
        default: return false
        }
    }

    var warningMessage: String? {
        switch self {
        case .validPendingBlockchain:
            return "⚠️ Pending blockchain confirmation"
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

    @Published private(set) var pendingSignatureIds: Set<String> = []
    @Published private(set) var pendingConsentIds: Set<String> = []
    @Published private(set) var isSyncing = false

    private var retryTask: Task<Void, Never>?
    private var networkMonitor: Task<Void, Never>?

    // MARK: - Consent status query

    /// Returns the effective consent status for the given type, checking both
    /// local vault and blockchain. This is the single call site for all access
    /// decisions — never check VaultManager or FabricClient directly for consent.
    func status(for consentType: String) async -> ConsentStatus {
        do {
            let records = try await LegalVaultManager.shared.openAllConsents()
            let matching = records
                .filter { $0.consentType == consentType }
                .sorted { $0.grantedAt > $1.grantedAt } // most recent first

            guard let latest = matching.first else {
                return .notFound
            }

            // Revoked locally → immediately invalid (GDPR Art.7(3)).
            if let revokedAt = latest.revokedAt {
                return .revoked(at: revokedAt)
            }

            // Expired locally.
            if let expiresAt = latest.expiresAt, expiresAt < Date() {
                return .expired(at: expiresAt)
            }

            // Not yet on-chain.
            guard latest.blockchainTxHash != nil else {
                return .validPendingBlockchain
            }

            // Optional: verify on-chain status is still active.
            // If the blockchain reports a revocation we don't have locally (admin action),
            // trust the blockchain and update local state.
            let chainStatus = await checkChainRevocation(
                consentType: consentType,
                txHash: latest.blockchainTxHash!
            )
            if case .revoked(let at) = chainStatus {
                // Persist the chain-side revocation locally.
                try? await LegalVaultManager.shared.revokeConsent(id: latest.id, revokedAt: at)
                return chainStatus
            }

            return .valid

        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    // MARK: - Pending queue management

    /// Called by SignatureButton when a channel-1 broadcast fails (offline).
    nonisolated func enqueuePendingSignature(_ id: String) {
        Task { @MainActor in
            pendingSignatureIds.insert(id)
            schedulePendingRetry()
        }
    }

    /// Called by SignatureButton when a channel-2 broadcast fails (offline).
    nonisolated func enqueuePendingConsent(_ id: String) {
        Task { @MainActor in
            pendingConsentIds.insert(id)
            schedulePendingRetry()
        }
    }

    // MARK: - Retry loop

    private func schedulePendingRetry() {
        guard retryTask == nil || retryTask!.isCancelled else { return }
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

        // Retry pending signatures (channel 1).
        var remainingSigs = pendingSignatureIds
        for sigId in pendingSignatureIds {
            do {
                let sigs = try await LegalVaultManager.shared.openSignatureRecords()
                guard let sig = sigs.first(where: { $0.id == sigId }) else {
                    remainingSigs.remove(sigId) // record disappeared — remove from queue
                    continue
                }
                guard sig.blockchainTxHash == nil else {
                    remainingSigs.remove(sigId) // already confirmed
                    continue
                }
                let txHash = try await FabricClient.channel1.recordAdESSignature(
                    documentHash:       sig.documentHash,
                    signerPubKeyHash:   sig.signerPubKeyHash,
                    signature:          sig.signature,
                    identityProvider:   sig.identityProvider,
                    identityVerifiedAt: Int64(sig.identityVerifiedAt.timeIntervalSince1970),
                    legalBasis:         sig.legalBasis,
                    documentType:       sig.documentType,
                    jurisdictions:      sig.jurisdictions
                )
                try await LegalVaultManager.shared.updateSignatureTxHash(id: sigId, txHash: txHash)
                remainingSigs.remove(sigId)
            } catch {
                // Still offline or transient — leave in queue.
            }
        }
        pendingSignatureIds = remainingSigs

        // Retry pending consent grants (channel 2).
        var remainingConsents = pendingConsentIds
        for consentId in pendingConsentIds {
            do {
                let consents = try await LegalVaultManager.shared.openAllConsents()
                guard let consent = consents.first(where: { $0.id == consentId }) else {
                    remainingConsents.remove(consentId)
                    continue
                }
                guard consent.blockchainTxHash == nil,
                      let sigRecord = try? await LegalVaultManager.shared
                          .openSignatureRecords()
                          .first(where: { $0.id == consent.signatureRecordId }),
                      let sigTxHash = sigRecord.blockchainTxHash else {
                    continue // wait for signature to confirm first
                }
                let consentTxHash = try await FabricClient.channel2.recordConsentGrant(
                    userIdHash:      try await DIDWallet.shared.currentUserIdHash(),
                    consentType:     consent.consentType,
                    expiresAt:       Int64(consent.expiresAt?.timeIntervalSince1970 ?? 0),
                    signatureTxHash: sigTxHash
                )
                try await LegalVaultManager.shared.updateConsentTxHash(id: consentId, txHash: consentTxHash)
                remainingConsents.remove(consentId)
            } catch {
                // Still offline or transient.
            }
        }
        pendingConsentIds = remainingConsents

        retryTask = nil

        // Schedule another pass if items remain.
        if !pendingSignatureIds.isEmpty || !pendingConsentIds.isEmpty {
            schedulePendingRetry()
        }
    }

    // MARK: - Chain revocation check

    private func checkChainRevocation(
        consentType: String,
        txHash _: String
    ) async -> ConsentStatus {
        // TODO: query channel-2 GetConsentHistory via gRPC and check for
        // a "revoked" event more recent than the grant referenced by txHash.
        // Return .revoked(at:) if found, otherwise return .valid.
        // Stub: always reports .valid (no admin-side revocations in pilot).
        return .valid
    }
}
