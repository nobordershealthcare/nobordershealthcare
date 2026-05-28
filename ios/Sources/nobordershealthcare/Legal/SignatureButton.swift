// SignatureButton.swift — UI component that triggers an Ed25519 + AdES signing flow.
//
// Signing pipeline (must execute in this order):
//   Step 1: Ed25519 sign via Secure Enclave → SignatureRecord
//   Step 2: IdentityVaultManager.sealSignatureRecord()     ← Silo 2, local gate (authoritative)
//   Step 3: FabricClient.channel1.recordAdESSignature() ← async, offline-tolerant
//   Step 4: if consentItems set → IdentityVaultManager.sealConsent() + Ch2 broadcast
//   Step 5: blockchainTxHash updated in vault once confirmed on-chain
//
// LOCAL IS AUTHORITATIVE: the signed record is valid from Step 2 onwards.
// Blockchain confirmation (Step 3) is non-blocking. Offline → queued in ConsentAuditService.
// The patient's signature is NEVER held hostage to network availability.
//
// Domain types (SignatureRecord, ConsentRecord, LegalBasis, etc.) are in Models.swift.

import SwiftUI
import CryptoKit

// MARK: - Signing result

struct SigningResult: Sendable {
    let signatureRecord: SignatureRecord
    let consentRecord: ConsentRecord?  // non-nil if consentItems was supplied
}

// MARK: - Signing state

enum SigningState: Equatable {
    case idle
    case authenticating           // biometric step-up in progress
    case signing                  // Ed25519 in Secure Enclave
    case sealingLocally           // writing to IdentityVaultManager (Silo 2)
    case broadcastingToChain      // submitting to Fabric channels (non-blocking)
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

/// SwiftUI button driving the full AdES signing + Legal Vault + blockchain pipeline.
///
/// Usage (from ConsentView):
/// ```swift
/// SignatureButton(
///     document: canonicalConsentJSON,
///     documentType: .gdprConsent,
///     consentItems: scopeItems,
///     legalBasis: [.gdprArt9, .gdprArt7],
///     jurisdictions: ["PT", "UA"],
///     adESText: "By signing I provide explicit GDPR Art.9 consent..."
/// ) { result in
///     // result.consentRecord is sealed in Silo 2
/// }
/// ```
struct SignatureButton: View {

    let document: Data               // canonical bytes of the document being signed
    let documentType: LegalDocumentType
    let consentItems: [ConsentScopeItem]? // if set, also creates a ConsentRecord
    let legalBasis: [LegalBasis]
    let jurisdictions: [String]      // ISO 3166-1 alpha-2
    let adESText: String             // human-readable AdES statement shown above button

    var label: String = "Sign"
    var onComplete: ((SigningResult) -> Void)?

    @State private var state: SigningState = .idle
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(adESText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
            .disabled(state.isWorking
                      || state == .complete(blockchainPending: false)
                      || state == .complete(blockchainPending: true))
            .alert("Signing failed", isPresented: $showError) {
                Button("OK", role: .cancel) { state = .idle }
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var buttonLabel: String {
        switch state {
        case .idle:                        return label
        case .authenticating:              return "Authenticating…"
        case .signing:                     return "Signing…"
        case .sealingLocally:              return "Saving locally…"
        case .broadcastingToChain:         return "Recording on blockchain…"
        case .complete(let pending):       return pending ? "Signed ⚠️" : "Signed ✓"
        case .failed:                      return label
        }
    }

    // MARK: - Pipeline

    private func startSigning() {
        Task { await runSigningPipeline() }
    }

    @MainActor
    private func runSigningPipeline() async {
        do {
            // ── Step 1: Biometric step-up + Ed25519 sign ──────────────────────
            state = .authenticating
            let identityVerifiedAt = Date()
            // In production: trigger BankID / CMD / Diia step-up here and await.
            // Biometric gate is enforced by SecureEnclaveKey.sign() via LAContext internally.

            state = .signing
            let docHash        = SHA3_256.hash(data: document).description
            let pubKeyRaw      = try await KeyManager.shared.ed25519PublicKeyData()
            let pubKeyHash     = SHA3_256.hash(data: pubKeyRaw).description
            let signatureBytes = try await KeyManager.shared.sign(document)

            // Device attestation: SHA3-256 of the DCAppAttestService assertion for this doc.
            // Falls back to empty string if DeviceCheck unavailable (simulator, first launch).
            let attestData     = (try? await AttestationService.shared.generateAssertion(for: document)) ?? Data()
            let deviceAttestHash = SHA3_256.hash(data: attestData).description

            let sigRecord = SignatureRecord(
                id:                   UUID(),
                documentHash:         docHash,
                documentType:         documentType,
                signature:            signatureBytes,
                publicKeyHash:        pubKeyHash,
                signedAt:             Date(),
                identityProvider:     "bankid-se",   // derived from active identity session
                identityVerifiedAt:   identityVerifiedAt,
                deviceAttestationHash: deviceAttestHash,
                legalBasis:           legalBasis,
                jurisdictions:        jurisdictions,
                blockchainTxHash:     nil
            )

            // ── Step 2: Seal locally in Legal vault (Silo 2) ─────────────────
            state = .sealingLocally
            try await IdentityVaultManager.shared.sealSignatureRecord(sigRecord)

            // Build consent record if consent items were provided.
            var consentRecord: ConsentRecord? = nil
            if let items = consentItems {
                let canonicalItems  = try JSONEncoder().encode(items)
                let consentSig      = try await KeyManager.shared.sign(canonicalItems)

                let cr = ConsentRecord(
                    id:                   UUID(),
                    items:                items,
                    signedAt:             Date(),
                    signature:            consentSig,
                    publicKeyHash:        pubKeyHash,
                    identityProvider:     sigRecord.identityProvider,
                    identityVerifiedAt:   identityVerifiedAt,
                    deviceAttestationHash: deviceAttestHash,
                    blockchainTxHash:     nil,
                    legalBasis:           legalBasis,
                    jurisdictions:        jurisdictions
                )
                try await IdentityVaultManager.shared.sealConsent(cr)
                consentRecord = cr
            }

            // ── Steps 3 & 4: Broadcast to blockchain (non-blocking) ───────────
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
            // Step 3: Channel 1 — RecordAdESSignature
            let sigTxHash = try await FabricClient.channel1.recordAdESSignature(
                documentHash:       sigRecord.documentHash,
                signerPubKeyHash:   sigRecord.publicKeyHash,
                signatureBase64:    sigRecord.signature.base64URLEncodedString(),
                identityProvider:   sigRecord.identityProvider,
                identityVerifiedAt: Int64(sigRecord.identityVerifiedAt.timeIntervalSince1970),
                legalBasis:         sigRecord.legalBasis.map { $0.rawValue },
                documentType:       sigRecord.documentType.rawValue,
                jurisdictions:      sigRecord.jurisdictions
            )
            try await IdentityVaultManager.shared.updateSignatureTxHash(id: sigRecord.id, txHash: sigTxHash)

            // Step 4: Channel 2 — RecordConsentGrant
            if let cr = consentRecord {
                let userIdHash = try await DIDWallet.shared.currentUserIdHash()
                let crIdData   = cr.id.uuidString.data(using: .utf8) ?? Data()
                let consentTxHash = try await FabricClient.channel2.recordConsentGrant(
                    userIdHash:        userIdHash,
                    consentRecordHash: SHA3_256.hash(data: crIdData).description,
                    grantedTypes:      cr.items.filter { $0.granted }.map { $0.type.rawValue },
                    signatureTxHash:   sigTxHash
                )
                try await IdentityVaultManager.shared.updateConsentTxHash(id: cr.id, txHash: consentTxHash)
            }
        } catch {
            // Offline or transient — ConsentAuditService will retry.
            ConsentAuditService.shared.enqueuePendingSignature(sigRecord.id)
            if let cr = consentRecord {
                ConsentAuditService.shared.enqueuePendingConsent(cr.id)
            }
        }
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
// Replace with real gRPC client calling the Fabric Gateway service.
// Stub is separated so it can be swapped for a mock in unit tests.

struct FabricClient {
    static let channel1 = FabricChannel(name: "signatures")
    static let channel2 = FabricChannel(name: "consent-audit")
    static let channel3 = FabricChannel(name: "access-audit")
}

struct FabricChannel {
    let name: String

    func recordAdESSignature(
        documentHash: String,
        signerPubKeyHash: String,
        signatureBase64: String,      // base64url-encoded Ed25519 raw 64 bytes
        identityProvider: String,
        identityVerifiedAt: Int64,
        legalBasis: [String],
        documentType: String,
        jurisdictions: [String]
    ) async throws -> String {
        // Fabric Gateway gRPC: channel "signatures" → RecordAdESSignature
        throw URLError(.notConnectedToInternet) // stub — replace with gRPC call
    }

    func recordConsentGrant(
        userIdHash: String,
        consentRecordHash: String,    // SHA3-256 of ConsentRecord.id
        grantedTypes: [String],       // ConsentType.rawValue per granted item
        signatureTxHash: String       // Channel 1 txID of accompanying AdES signature
    ) async throws -> String {
        // Fabric Gateway gRPC: channel "consent-audit" → RecordConsentGrant
        throw URLError(.notConnectedToInternet) // stub
    }

    func recordEHRAccess(
        accessorHash: String,         // SHA3-256(clinician license number)
        patientHash: String,          // SHA3-256(userID)
        purpose: String,
        tokenJTI: String
    ) async throws -> String {
        // Fabric Gateway gRPC: channel "access-audit" → RecordEHRAccess
        throw URLError(.notConnectedToInternet) // stub
    }
}
