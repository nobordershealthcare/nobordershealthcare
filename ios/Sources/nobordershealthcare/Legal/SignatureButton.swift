// SignatureButton.swift — UI component that triggers an Ed25519 + AdES signing flow.
//
// Signing pipeline (must execute in this order):
//   Step 1: Ed25519 sign via Secure Enclave → SignatureRecord
//   Step 2: LegalVaultManager.sealSignatureRecord()   ← local, synchronous gate
//   Step 3: blockchain.RecordAdESSignature()           ← channel 1, async, offline-tolerant
//   Step 4: if consentType set → blockchain.RecordConsentGrant() ← channel 2
//   Step 5: update blockchainTxHash in vault once on-chain confirmation arrives
//
// LOCAL IS AUTHORITATIVE: the signed record is valid the moment it is sealed in
// the Legal vault (Step 2). The blockchain confirmation (Step 3) is non-blocking.
// If the device is offline, the pending tx is queued and retried when connectivity
// returns. The patient's signature is never held hostage to network availability.

import SwiftUI
import CryptoKit

// MARK: - Signing result

struct SigningResult: Sendable {
    let signatureRecord: SignatureRecord
    let consentRecord: ConsentRecord?  // non-nil if consentType was supplied
}

// MARK: - Signing state

enum SigningState: Equatable {
    case idle
    case authenticating          // BankID/biometric step-up in progress
    case signing                 // Ed25519 in SE
    case sealingLocally          // writing to LegalVaultManager
    case broadcastingToChain     // submitting to Fabric channels (non-blocking)
    case complete(blockchainPending: Bool)
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .authenticating, .signing, .sealingLocally, .broadcastingToChain: return true
        default: return false
        }
    }
}

// MARK: - SignatureButton

/// A SwiftUI button that drives the full AdES signing + Legal vault + blockchain pipeline.
///
/// Usage:
/// ```swift
/// SignatureButton(
///     document: myConsentDocument,
///     documentType: "consent",
///     consentType: "ehr_access",
///     legalBasis: ["Art.6(1)(a)", "Art.9(2)(a)"],
///     jurisdictions: ["PT"]
/// ) { result in
///     print("Signed: \(result.signatureRecord.id)")
/// }
/// ```
struct SignatureButton: View {

    let document: Data            // raw bytes of the document to sign
    let documentType: String      // "consent" | "healthcare_proxy" | "dpa" | "ehr_access"
    let consentType: String?      // if set, also records a ConsentGrant on channel 2
    let legalBasis: [String]      // GDPR Art. references
    let jurisdictions: [String]   // ISO 3166-1 alpha-2

    var label: String = "Sign"
    var onComplete: ((SigningResult) -> Void)? = nil

    @State private var state: SigningState = .idle
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        Button(action: startSigning) {
            HStack(spacing: 8) {
                if state.isWorking {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: "signature")
                }
                Text(buttonLabel)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.isWorking || state == .complete(blockchainPending: false) || state == .complete(blockchainPending: true))
        .alert("Signing failed", isPresented: $showError) {
            Button("OK", role: .cancel) { state = .idle }
        } message: {
            Text(errorMessage)
        }
    }

    private var buttonLabel: String {
        switch state {
        case .idle:                              return label
        case .authenticating:                    return "Authenticating…"
        case .signing:                           return "Signing…"
        case .sealingLocally:                    return "Saving locally…"
        case .broadcastingToChain:               return "Recording on blockchain…"
        case .complete(let pending):             return pending ? "Signed ⚠️" : "Signed ✓"
        case .failed:                            return label
        }
    }

    // MARK: - Pipeline

    private func startSigning() {
        Task { await runSigningPipeline() }
    }

    @MainActor
    private func runSigningPipeline() async {
        do {
            // ── Step 1: BankID / biometric step-up + Ed25519 sign ─────────────
            state = .authenticating
            let identityVerifiedAt = Date()
            // In production: trigger BankID step-up here and await completion.
            // For now, biometric gate is enforced by SecureEnclaveKey.sign() calling
            // LAContext evaluation internally.

            state = .signing
            let docHash   = sha3_256(document)
            let pubKeyDER = try await KeyManager.shared.ed25519PublicKeyDERData()
            let pubKeyHash = sha3_256(pubKeyDER)
            let signatureBytes = try await KeyManager.shared.sign(document)
            let signatureB64   = signatureBytes.base64URLEncodedString()

            let sigRecord = SignatureRecord(
                id:                 UUID().uuidString,
                documentHash:       docHash,
                signerPubKeyHash:   pubKeyHash,
                signature:          signatureB64,
                identityProvider:   "bankid-se", // TODO: derive from active BankID session
                identityVerifiedAt: identityVerifiedAt,
                legalBasis:         legalBasis,
                documentType:       documentType,
                jurisdictions:      jurisdictions,
                createdAt:          Date(),
                blockchainTxHash:   nil
            )

            // ── Step 2: Seal locally in Legal vault ───────────────────────────
            // This is the authoritative record. Must succeed before Step 3.
            state = .sealingLocally
            try await LegalVaultManager.shared.sealSignatureRecord(sigRecord)

            // Build consent record if a consentType was provided.
            var consentRecord: ConsentRecord? = nil
            if let ct = consentType {
                let cr = ConsentRecord(
                    id:               UUID().uuidString,
                    consentType:      ct,
                    grantedAt:        Date(),
                    revokedAt:        nil,
                    expiresAt:        nil,
                    signatureRecordId: sigRecord.id,
                    blockchainTxHash: nil
                )
                try await LegalVaultManager.shared.sealConsent(cr)
                consentRecord = cr
            }

            // ── Steps 3 & 4: Broadcast to blockchain (non-blocking) ───────────
            // Fire-and-forget. The local record is already the source of truth.
            // ConsentAuditService monitors pending txs and updates the vault when confirmed.
            state = .broadcastingToChain
            let result = SigningResult(signatureRecord: sigRecord, consentRecord: consentRecord)

            Task.detached(priority: .background) {
                await broadcastToBlockchain(sigRecord: sigRecord, consentRecord: consentRecord)
            }

            // ── Step 5 happens asynchronously in ConsentAuditService ──────────
            state = .complete(blockchainPending: true)
            onComplete?(result)

        } catch {
            state = .idle
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    // MARK: - Blockchain broadcast (background, offline-tolerant)

    private func broadcastToBlockchain(
        sigRecord: SignatureRecord,
        consentRecord: ConsentRecord?
    ) async {
        do {
            // Step 3: channel 1 — RecordAdESSignature
            let sigTxHash = try await FabricClient.channel1.recordAdESSignature(
                documentHash:       sigRecord.documentHash,
                signerPubKeyHash:   sigRecord.signerPubKeyHash,
                signature:          sigRecord.signature,
                identityProvider:   sigRecord.identityProvider,
                identityVerifiedAt: Int64(sigRecord.identityVerifiedAt.timeIntervalSince1970),
                legalBasis:         sigRecord.legalBasis,
                documentType:       sigRecord.documentType,
                jurisdictions:      sigRecord.jurisdictions
            )
            try await LegalVaultManager.shared.updateSignatureTxHash(id: sigRecord.id, txHash: sigTxHash)

            // Step 4: channel 2 — RecordConsentGrant (only if consent type is set)
            if let cr = consentRecord {
                let consentTxHash = try await FabricClient.channel2.recordConsentGrant(
                    userIdHash:      try await currentUserIdHash(),
                    consentType:     cr.consentType,
                    expiresAt:       Int64(cr.expiresAt?.timeIntervalSince1970 ?? 0),
                    signatureTxHash: sigTxHash
                )
                try await LegalVaultManager.shared.updateConsentTxHash(id: cr.id, txHash: consentTxHash)
            }
        } catch {
            // Offline or transient failure — ConsentAuditService will retry.
            // The local vault record is already sealed; the signature is valid without the tx hash.
            ConsentAuditService.shared.enqueuePendingSignature(sigRecord.id)
            if let cr = consentRecord {
                ConsentAuditService.shared.enqueuePendingConsent(cr.id)
            }
        }
    }

    // MARK: - Helpers

    private func sha3_256(_ data: Data) -> String {
        // SHA3-256 via SHA3Kit (the local package target).
        // Import SHA3Kit or use the CryptoKit SHA256 bridge — see SHA3Kit/SHA3.swift.
        // Placeholder: real implementation delegates to SHA3Kit.sha3_256(data).
        var hash = [UInt8](repeating: 0, count: 32)
        // sha3_256_bytes(data.bytes, data.count, &hash)  ← real call site
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func currentUserIdHash() async throws -> String {
        // Fetched from KeyManager / DIDWallet — the on-device identity hash.
        // Placeholder: real implementation reads from DIDWallet.shared.currentUserIdHash().
        return try await DIDWallet.shared.currentUserIdHash()
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

// MARK: - FabricClient stub
// Replace with the real gRPC client that talks to the Fabric Gateway service.
// Separated here so the stub can be swapped for a mock in unit tests.

struct FabricClient {
    static let channel1 = FabricChannel(name: "signatures")
    static let channel2 = FabricChannel(name: "consent-audit")
}

struct FabricChannel {
    let name: String

    func recordAdESSignature(
        documentHash: String,
        signerPubKeyHash: String,
        signature: String,
        identityProvider: String,
        identityVerifiedAt: Int64,
        legalBasis: [String],
        documentType: String,
        jurisdictions: [String]
    ) async throws -> String {
        // TODO: call Fabric Gateway gRPC endpoint.
        // Returns the Fabric txID on success.
        throw URLError(.notConnectedToInternet) // stub — always fails offline
    }

    func recordConsentGrant(
        userIdHash: String,
        consentType: String,
        expiresAt: Int64,
        signatureTxHash: String
    ) async throws -> String {
        // TODO: call Fabric Gateway gRPC endpoint.
        throw URLError(.notConnectedToInternet) // stub
    }
}
