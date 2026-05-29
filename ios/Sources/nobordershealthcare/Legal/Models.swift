// Models.swift — Canonical legal-domain types for the nobordershealthcare iOS wallet.
//
// These types are the single source of truth for:
//   SILO 1 — iOS Identity Vault (IdentityVaultManager, key: com.noborders.identity.key)
//   SILO 4 — Hyperledger Fabric Ch1 (AdES signatures), Ch2 (consent-audit)
//
// SILO BOUNDARY RULE:
//   ConsentRecord, HealthcareProxy, DataProcessingAuthorization, SignatureRecord
//   → Identity Vault (Silo 1) ONLY. Never touch MedicalVaultManager or com.noborders.medical.key.
//   EmergencyCard → Medical Vault (Silo 2) ONLY.
//
// Hashing: SHA3-256 (SHA3Kit) throughout — never SHA-2 family digests.
// Blockchain writes: hashes only — never content, paths, or URLs.
// Medications: ATC codes — NEVER RxNorm.

import Foundation

// MARK: - Profile classification (single source of truth — also in ProfileTypeStore/IdentityVaultManager)

enum ProfileType: String, Codable, Sendable {
    case civilian        // default
    case military        // ЗСУ, NATO armed forces
    case firstResponder  // paramedic, firefighter
    case corporate       // company employee (bulk import)
    case family          // family member (bulk import)
}

// Operational role — orthogonal to ProfileType.
// A Gendarmerie officer is both .military + .gendarmerie.
enum OperationalRole: String, Codable, Sendable {
    case none            // civilian default
    case lawEnforcement  // police, patrol
    case specialOps      // SBU, SSO, GSG9, RAID, GIGN — covert protection
    case nationalGuard   // НГУ (UA-MVS), NG (US-DoD)
    case gendarmerie     // FR Gendarmerie, IT Carabinieri, ES Guardia Civil, PT GNR
                         // military structure + police role
    case civilDefense    // ДСНС, THW, Sécurité Civile, IT Protezione Civile, PT ANEPC
    case fireRescue      // fire department
    case sarTeam         // INSARAG / UCPM USAR teams
    case euBorderGuard   // Frontex, national border police
    case europolOfficer  // Europol operational staff
}

// Controls what appears on Emergency Card QR.
// Rule: Emergency Card contains ONLY what saves lives.
enum IdentityProtectionLevel: String, Codable, Sendable {
    case standard  // civilian — full name, full data
    case reduced   // military — service number, no unit
    case minimal   // police/NGU — no affiliation shown
    case covert    // special ops — blood type + allergies ONLY
                   // command channel only, never direct disclosure
}

// Authority — for kin notification routing and DVI database selection.
enum AuthorityType: String, Codable, Sendable {
    // Ukraine
    case ua_mo           // МО України
    case ua_mvs          // МВС (includes НГУ)
    case ua_sbu          // СБУ
    case ua_dsns         // ДСНС
    case ua_civilian     // civilian, no authority
    // EU — national
    case eu_police       // generic national police
    case eu_gendarmerie  // FR/IT/ES/PT military-police
    case eu_special      // ATLAS Network member
    case eu_civil        // UCPM / civil protection
    case eu_border       // Frontex / border guard
    case eu_interpol     // Interpol liaison officer
    // Multinational
    case nato            // NATO SOFA covered
    case interpol        // Interpol direct
}

// Legal basis for data processing.
// Determines which regulation governs this profile.
enum LegalBasisType: String, Codable, Sendable {
    case gdpr_art9       // civilian medical — GDPR Art.9.2(a) + Art.9.2(c)
    case led_art10       // EU Law Enforcement Directive 2016/680 Art.10 — EU police
    case nato_stanag     // STANAG 2154 — NATO military
    case vital_interests // GDPR Art.9.2(c) — unconscious patient
}

// MARK: - Operational profile (stored in Legal Vault, key: com.noborders.operational.profile)

struct OperationalProfile: Codable, Sendable {
    var profileType: ProfileType
    var operationalRole: OperationalRole
    var identityProtection: IdentityProtectionLevel
    var authority: AuthorityType
    var legalBasis: LegalBasisType

    // NOK routing
    var nokNotifyDirect: Bool
    // true  = notify family directly
    // false = notify via duty officer / command first

    // Cross-border (Schengen Art.40-41)
    var schengenCrossBorder: Bool
    // If injured in another Schengen country:
    // true = NOK routed via Europol SIENA first

    // EU Civil Protection
    var eucpId: String?
    // Format: "UCPM-{country}-{year}-{number}"

    // EU Special Ops
    var atlasNetworkId: String?
    // Format: "ATLAS-{country}-{unit_hash}"
    // unit_hash = SHA3-256(unit_designation) — never store unit designation plaintext

    // CBRN exposure history
    var cbrnExposureHistory: CBRNExposure?

    // Law enforcement mental health flag
    // true = treating physician sees mental health meds — NOT on standard emergency card
    var hasPsychologicalMedications: Bool

    // Computed: what goes into Emergency QR JWT
    var emergencyCardScope: [String] {
        switch identityProtection {
        case .standard:
            return ["name", "dob", "blood_type", "allergies",
                    "medications", "nok_direct"]
        case .reduced:
            return ["service_number", "blood_type", "allergies",
                    "medications", "dna_reference", "nok_via_duty"]
        case .minimal:
            return ["blood_type", "allergies",
                    "medications", "nok_via_duty"]
        case .covert:
            return ["blood_type", "allergies"]
            // command channel only — kin notification not in QR payload
        }
    }
}

struct CBRNExposure: Codable, Sendable {
    var radiationDoseRemainingMSv: Double?
    var lastDecontaminationDate: Date?
    var chemicalExposures: [String]
    var kiDosesAdministered: Int    // potassium iodide doses
    var cbrnCertificationLevel: String? // "HAZMAT-A", etc.
}

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

    // GDPR Art.9 + LED Art.10 — forensic DNA analysis.
    // MUST be presented and signed separately from all other consent types.
    // The iOS UI must show a dedicated full-screen consent flow for this case,
    // with explicit mention of "DNA" and the processing authority.
    // This consent may NOT be bundled with standard medical or research consent.
    // Corresponds to channel-2 consent_type = "forensic_dna".
    case forensicDNA          // Forensic DNA analysis — separate, granular consent required
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

// MARK: - Military profile (STANAG 2154 compliant)
// Stored in Silo 2 (Legal Vault, com.noborders.legal.key).
// Only what saves lives — see exclusion list below.

// EXPLICITLY EXCLUDED (never stored — see rule below):
// ❌ Security clearance — never stored, security risk on unconscious body
// ❌ Unit designation — never stored, operational security
// ❌ Rank — never stored, irrelevant for medical treatment
// ❌ Tactical information of any kind — never stored
// Rule: Emergency Card contains ONLY what saves lives

struct MessengerHandle: Codable, Sendable {
    var platform: String   // "telegram" | "whatsapp" | "signal" | "viber"
    var handle: String     // username or phone-linked handle
}

struct NextOfKin: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var relationship: String       // "spouse" | "parent" | "sibling"
    var phone: String              // E.164
    var messenger: MessengerHandle?
    var notifyOnCasualty: Bool     // true = notify if injured/KIA
    var priority: Int              // 1 = first to notify
    var viaCommandOnly: Bool       // true for special-ops profiles — command-channel routing only
}

struct IdentifyingMark: Codable, Identifiable, Sendable {
    let id: UUID
    var type: String               // "tattoo" | "scar" | "birthmark"
    var location: String           // e.g. "left forearm, inner"
    var description: String
    var photoHash: String?         // SHA3-256(photo) — never the photo itself
}

struct MilitaryIdentification: Codable, Sendable {

    // Identity — for DVI and MEDEVAC radio report
    var serviceNumber: String      // personal military ID only
    var nationality: String        // ISO 3166-1 alpha-2

    // Medical — critical for treatment
    var bloodTypeVerified: Bool    // true = genetic confirmation; false = self-reported
    var dnaReferenceNumber: String // NATO DNA DB or UA MO registry reference
    var dnaStandard: String        // "ESS" (European Standard Set) or "CODIS" (US)
    var dentalRecordReference: String?

    // Next of Kin — up to 3, priority order
    var nextOfKin: [NextOfKin]     // max 3 entries

    // Identifying marks — for DVI (Disaster Victim Identification)
    var identifyingMarks: [IdentifyingMark]
    var prosthetics: [String]?

    // Medical preferences
    var bloodTransfusionConsent: Bool  // true for most military personnel
    var organDonorConsent: Bool        // DD Form 93 equivalent

    // Religious preference — for burial procedures if KIA
    var religiousPreference: String?   // e.g. "Orthodox", "Catholic", "Muslim"
}
