// Models.swift — Canonical legal-domain types for the nobordershealthcare iOS wallet.
//
// These types are the single source of truth for:
//   SILO 2 — iOS Legal Vault (LegalVaultManager, key: com.noborders.legal.key)
//   SILO 3 — Hyperledger Fabric Ch1 (AdES signatures), Ch2 (consent-audit)
//
// SILO BOUNDARY RULE:
//   ConsentRecord, HealthcareProxy, DataProcessingAuthorization, SignatureRecord
//   → Legal Vault (Silo 2) ONLY. Never touch VaultManager or com.noborders.vault.key.
//   EmergencyCard → eHR Vault (Silo 1) ONLY.
//
// Hashing: SHA3-256 (SHA3Kit) everywhere — NEVER crypto/sha256.
// Blockchain writes: hashes only — never content, paths, or URLs.
// Medications: ATC codes — NEVER RxNorm.

import Foundation

// MARK: - Consent types (12 total — maps to GDPR toggle list in ConsentView)

enum ConsentType: String, Codable, CaseIterable, Sendable {
    case localStorage         // Store emergency medical data on this device
    case cloudBackup          // Encrypted cloud backup (EU servers)
    case p2pBackup            // Encrypted P2P backup (IPFS, encrypted shards)
    case emergencyAccess      // Allow emergency access via QR code (REQUIRED)
    case proxyAccess          // Healthcare proxy can access your data
    case crossBorderEU        // Transfer data within EU (Art.44)
    case crossBorderUkraine   // Transfer data to Ukraine (Art.46 safeguards)
    case researchAnonymized   // Anonymized research use
    case dataReceiptFromClinics   // Receive medical data from clinics
    case dataTransferToClinics    // Send medical data to clinics
    case clinicianVerification    // Clinician identity verification logging
    case documentTranslation      // Document translation processing
}

// MARK: - Legal basis references (eIDAS, GDPR, national law)

enum LegalBasis: String, Codable, Sendable {
    case gdprArt9   = "GDPR-Regulation-2016/679-Art9"
    case gdprArt7   = "GDPR-Regulation-2016/679-Art7"
    case eidasArt25 = "eIDAS-Regulation-910/2014-Art25"
    case uaLaw2017  = "UA-Law-2017-2155-VIII"
    case ptLei25    = "PT-Lei-25/2012"
    case deBGB1901a = "DE-BGB-§1901a"
    case euMDR      = "EU-MDR-2017/745-ClassIIa"
}

// MARK: - Consent scope item (one GDPR toggle)

/// One independently toggleable consent item.
/// titleKey / descriptionKey are NSLocalizedString keys — use Text(LocalizedStringKey(item.titleKey)).
/// required items must remain granted = true before onboarding can complete.
struct ConsentScopeItem: Codable, Identifiable, Sendable {
    let id: UUID
    let type: ConsentType
    let required: Bool             // cannot proceed without this consent
    let titleKey: String           // localization key, e.g. "consent.localStorage.title"
    let descriptionKey: String     // localization key for expanded explanation
    let legalBasis: [LegalBasis]
    var granted: Bool
    var grantedAt: Date?           // set when user grants
    var revokedAt: Date?           // set on revocation; nil = still active if granted
}

// MARK: - Consent record (atomic — all items signed together as one EdDSA signature)

struct ConsentRecord: Codable, Identifiable, Sendable {
    let id: UUID
    var items: [ConsentScopeItem]  // var to allow per-item revocation
    let signedAt: Date
    let signature: Data            // Ed25519 raw 64 bytes over canonical JSON of items
    let publicKeyHash: String      // SHA3-256 of signer's Ed25519 public key DER
    let identityProvider: String   // "bankid-se" | "cmd-pt" | "diia-ua" | "npa-de" | "eidas"
    let identityVerifiedAt: Date
    let deviceAttestationHash: String  // SHA3-256 of DCAppAttestService receipt
    var blockchainTxHash: String?  // Ch2 tx — nil until on-chain confirmation
    let legalBasis: [LegalBasis]
    let jurisdictions: [String]    // ISO 3166-1 alpha-2
}

// MARK: - Healthcare proxy

struct HealthcareProxy: Codable, Identifiable, Sendable {
    let id: UUID
    let proxyName: String
    let phone: String
    let email: String
    let scope: ProxyScope
    let triggers: [ProxyTrigger]
    let validFrom: Date
    let validUntil: Date?          // nil = indefinite
    let signature: Data            // patient Ed25519 raw 64 bytes
    var blockchainTxHash: String?  // Ch1 tx
    let jurisdictions: [String]    // ISO 3166-1 alpha-2
    let legalReferences: [LegalBasis]
}

enum ProxyScope: String, Codable, Sendable {
    case informOnly         // no decisions, inform only
    case advisory           // consult proxy; doctor decides
    case fullDecisionMaking // full medical authority

    var displayLabel: String {
        switch self {
        case .informOnly:         return "Inform only — update on my status"
        case .advisory:           return "Advisory — consult, but doctor decides"
        case .fullDecisionMaking: return "Full authority — make medical decisions for me"
        }
    }
}

enum ProxyTrigger: String, Codable, CaseIterable, Sendable {
    case unconscious
    case coma
    case anyIncapacity
    case surgicalAnesthesia

    var displayLabel: String {
        switch self {
        case .unconscious:        return "Unconscious"
        case .coma:               return "Coma or vegetative state"
        case .anyIncapacity:      return "Any incapacity to communicate"
        case .surgicalAnesthesia: return "Surgical anesthesia"
        }
    }
}

// MARK: - Proxy document (official paper attached to HealthcareProxy — stored in Silo 2)
//
// Example scenario (ONLY in code comments, never in UI or storage):
// Valeriy Indyk acts as healthcare proxy for his wife. He uploads the notarized
// Vorsorgevollmacht. At Hospital da Luz, ER doctor scans the patient QR.
// Valeriy shares the proxy document with a one-time link. Doctor sees:
// Ukrainian document + Portuguese translation. Access logged on blockchain.
// Both parties notified.

struct ProxyDocument: Codable, Identifiable, Sendable {
    let id: UUID
    let proxyId: UUID              // links to HealthcareProxy.id
    let documentType: ProxyDocumentType
    let originalPages: [Data]      // encrypted JPEG scans (within Legal Vault blob)
    let ocrText: [String]          // per-page OCR text, original language
    let detectedLanguage: String   // ISO 639-1 (e.g. "uk", "de", "pt")
    let translations: [String: [String]] // langCode → [pageTexts], e.g. "pt" → [...]
    let uploadedAt: Date
    let sha3Hash: String           // SHA3-256 of concatenated original scan bytes
    var blockchainTxHash: String?  // Ch1 proof of existence at upload timestamp
    var shareGrants: [ProxyDocumentShareGrant]
}

enum ProxyDocumentType: String, Codable, Sendable {
    case powerOfAttorney          // Vorsorgevollmacht / доручення
    case courtOrder               // судове рішення
    case guardianshipCertificate  // свідоцтво про опіку
    case notarizedDeclaration     // нотаріальна заява
    case hospitalForm             // лікарняна форма
}

struct ProxyDocumentShareGrant: Codable, Identifiable, Sendable {
    let id: UUID
    let sharedAt: Date
    let recipientType: ShareRecipient
    let recipientHash: String      // SHA3-256(clinician license number or institution ID)
    let scopeDescription: String   // what was shared and why (free text, patient-visible)
    let expiresAt: Date            // share link TTL
    let oneTimeToken: String       // UUID string — invalidated after first access (Redis NX)
    let signature: Data            // proxy owner Ed25519 sign of grant terms
    var accessedAt: Date?          // set when recipient opens the document
    var blockchainTxHash: String?  // Ch3 access-audit tx
}

enum ShareRecipient: String, Codable, Sendable {
    case emergencyDepartment
    case clinic
    case legalAuthority
    case insurance
    case court
}

// MARK: - Data processing authorization (GDPR Art.28 DPA)

struct DataProcessingAuthorization: Codable, Identifiable, Sendable {
    let id: UUID
    let grantorHash: String        // SHA3-256(userID) — never plaintext user ID
    let grantee: String            // "nobordershealthcare-platform"
    let receiveFrom: [DataSource]
    let storagePermissions: [StoragePermission]
    let transferTo: [DataRecipient]
    let processingPurposes: [ProcessingPurpose]
    let validFrom: Date
    let validUntil: Date?          // nil = indefinite
    let governingLaw: [String]     // e.g. ["EU-GDPR","UA-2021","PT-RGPD"]
    let signature: Data            // patient Ed25519 raw 64 bytes
    var blockchainTxHash: String?  // Ch2 tx
}

enum DataSource: String, Codable, CaseIterable, Sendable {
    case ukraineEHealth  = "ua-ehealth"     // Ukrainian МОЗ national eHealth system
    case germanEPA       = "de-epa"         // German elektronische Patientenakte
    case portugueseSNS   = "pt-sns"         // Portuguese Serviço Nacional de Saúde
    case specificClinic  = "specific-clinic"// Named institution (metadata stored separately)
}

enum StoragePermission: String, Codable, CaseIterable, Sendable {
    case onDevice       = "on-device"       // Silo 1 only
    case euCloud        = "eu-cloud"        // Silo 4 (ScyllaDB, EU-only buckets)
    case p2pDistributed = "p2p-distributed" // Silo 5 (IPFS + Shamir K=3/N=7)
}

struct DataRecipient: Codable, Identifiable, Sendable {
    let id: UUID
    let type: DataRecipientType
    let name: String               // institution or role name — not a person's name
    let country: String            // ISO 3166-1 alpha-2
    let purpose: String            // free-text description of sharing purpose
}

enum DataRecipientType: String, Codable, Sendable {
    case emergencyDepartment
    case healthcareProxy
    case specificInstitution
}

enum ProcessingPurpose: String, Codable, CaseIterable, Sendable {
    case emergencyAssistance  // rendering emergency medical care
    case documentTranslation  // translating clinical documents on-device
    case medicalSummary       // generating clinical summaries
    case ipsGeneration        // building FHIR R4 International Patient Summary
}

// MARK: - Signature record (AdES — NEVER stored in Silo 1)
// Stored in Silo 2 (Legal Vault) and anchored on Fabric Channel 1.

struct SignatureRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let documentHash: String       // SHA3-256 of signed document bytes (hex, 64 chars)
    let documentType: LegalDocumentType
    let signature: Data            // Ed25519 raw 64 bytes
    let publicKeyHash: String      // SHA3-256 of signer's Ed25519 public key DER
    let signedAt: Date
    let identityProvider: String   // "bankid-se" | "cmd-pt" | "diia-ua" | "npa-de" | "eidas"
    let identityVerifiedAt: Date
    let deviceAttestationHash: String // SHA3-256 of DCAppAttestService receipt
    let legalBasis: [LegalBasis]
    let jurisdictions: [String]    // ISO 3166-1 alpha-2
    var blockchainTxHash: String?  // Channel 1 tx ID — nil until confirmed
}

enum LegalDocumentType: String, Codable, Sendable {
    case gdprConsent
    case healthcareProxy
    case dataProcessingAuth
    case emergencyCardActivation
    case clinicDataRequest
    case proxyDocumentUpload       // proof-of-existence for official proxy document
}

// MARK: - Blood type (used in EmergencyCard — stored in Silo 1)

enum BloodType: String, Codable, CaseIterable, Sendable {
    case aPos  = "A+"
    case aNeg  = "A-"
    case bPos  = "B+"
    case bNeg  = "B-"
    case oPos  = "O+"
    case oNeg  = "O-"
    case abPos = "AB+"
    case abNeg = "AB-"
}

// MARK: - EmergencyCard (stored in Silo 1 — eHR vault, NOT Legal vault)
// NOTE: the ScopedTokenActor (eHR/EmergencyCard.swift) manages JWT issuance from this struct.

struct EmergencyCard: Codable, Identifiable, Sendable {
    let id: UUID
    var displayName: String        // "Maria K." — first name + last initial only, max 50 chars
    var dateOfBirth: Date
    var bloodType: BloodType
    var allergies: [String]        // SNOMED-coded where possible; display names for ER
    var medications: [Medication]
    var updatedAt: Date
}

// MARK: - Medication (simplified for emergency display)
// Full clinical record lives in openEHR Composition as MedicationEntry with ATC code.

struct Medication: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var dose: String
    var frequency: String
    var atcCode: String?           // ATC code from normalization module — NEVER RxNorm
}
