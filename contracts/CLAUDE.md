# Hyperledger Fabric Chaincode — Module Context

## Language: Go 1.22+  |  Fabric: 2.5 LTS

## 5-Channel Architecture

Each Fabric channel is a separate blockchain ledger with its own chaincode deployment,
world state, and endorsement policy. Channels share no data.

| Channel | Directory | Purpose |
|---------|-----------|---------|
| `signatures` | contracts/channel1-signatures/ | AdES legally-binding signature records |
| `consent-audit` | contracts/channel2-consent/ | GDPR Art.7 consent lifecycle |
| `access-audit` | contracts/channel3-access/ | GDPR Art.15 eHR access log |
| `military` | contracts/channel4-military/ | STANAG 2154 military profile access |
| `token-distribution` | contracts/channel5-token/ | NBHC token revenue distribution + MiCA audit |
| *(access control)* | contracts/ | Permission grants/revocations (this directory) |

## What goes ON-CHAIN (only this, nothing else)
- SHA3-256 hashes of identifiers — NEVER plaintext IDs, names, or health data
- SHA3-256 hashes of signatures and public keys — NEVER raw credential material
- Timestamps from `GetTxTimestamp()` — NEVER `time.Now()`
- Fabric transaction IDs for cross-channel referencing
- Consent event types (string enum) and scope arrays ([]string enum values)

## What NEVER goes on-chain
- Any plaintext, any health data, file paths, URLs, IP addresses
- Mapping between hash(docID) and storage location
- Raw signatures, certificates, or public keys
- Patient names, DOB, national IDs, or any GDPR Art.4 personal data

## Channel 1: signatures — chaincode functions
```go
// Record an AdES (Advanced Electronic Signature) after BankID/eID step-up.
// documentHash = SHA3-256 of the signed document bytes.
// signerPubKeyHash = SHA3-256 of the signer's Ed25519 public key DER bytes.
// signature = base64url(Ed25519 raw signature) — stored as string, not bytes.
RecordAdESSignature(ctx,
    documentHash, signerPubKeyHash, signature,
    identityProvider, identityVerifiedAt,
    legalBasis[], documentType, jurisdictions[])
    → txID string

// Retrieve the signature record for a given document hash.
// Returns ErrRecordNotFound if no signature exists (not an error for the caller).
VerifyAdESSignature(ctx, documentHash)
    → SignatureRecord | ErrRecordNotFound
```

## Channel 2: consent-audit — chaincode functions
```go
// Record patient consent grant. signatureTxHash = channel-1 txID of the
// AdES signature for this consent document.
RecordConsentGrant(ctx,
    userIdHash, consentType, expiresAt, signatureTxHash)
    → txID string

// Record patient consent revocation. Revocation is immediate — no grace period.
// The original grant record remains on the ledger (append-only).
RecordConsentRevoke(ctx,
    userIdHash, consentType, revokedAt)
    → txID string

// Return full consent lifecycle for GDPR Art.15 right-of-access responses.
GetConsentHistory(ctx, userIdHash)
    → []ConsentAuditRecord
```

## Channel 3: access-audit — chaincode functions
```go
// Log a real eHR data access event (doctor opening a patient record).
// consentRef = channel-2 txID of the governing consent record.
// signatureRef = channel-1 txID of the accessor's session signature.
RecordEHRAccess(ctx,
    patientIdHash, accessorIdHash, accessorType,
    licenseHash, accessScope[], duration,
    consentRef, signatureRef)
    → txID string

// Return full access log for GDPR Art.15 right-of-access responses.
GetAccessHistory(ctx, patientIdHash)
    → []AccessAuditRecord
```

## Access control chaincode (this directory)
```go
// 1. Patient grants role access to their docID
GrantAccess(ctx, hashedUserID, hashedDocID, role, scope, ttlSeconds)

// 2. Patient revokes access immediately
RevokeAccess(ctx, hashedUserID, hashedDocID, role)

// 3. Gatekeeper queries: is this access permitted?
VerifyAccess(ctx, hashedRequesterID, hashedDocID, role) → (allowed bool, role, scope)

// 4. Anonymizer logs access event (fire-and-forget)
LogAccessEvent(ctx, hashedRequesterID, hashedDocID, action, result)

// 5. Patient requests GDPR Art.15 access log
QueryAuditTrail(ctx, hashedUserID) → []AuditEntry

// 6. Admin force-reassign (requires 2 admin signatures)
ReassignRole(ctx, hashedUserID, hashedDocID, oldRole, newRole, cosignerAdminHash)

// 7. Admin force-assemble eHR (requires 2 admin signatures)
ForceAssemble(ctx, hashedUserID, hashedDocID, role, expiry, cosignerAdminHash)
```

## Endorsement policy
- Standard: 2-of-3 peer endorsement
- Admin operations: 3-of-3 + HSM signature verification
- No single point of authority

## Invariants (verify formally)
- User CANNOT escalate their own role
- Only patient can grant access to their own records
- ForceAssemble and ReassignRole require TWO DISTINCT admin cert hashes
- ConsentRevocation is immediate — no grace period
- All audit logs are append-only — no delete function exists in any channel
- Cross-channel references use txID strings — never embed data from another channel

## Channel 5: token-distribution — chaincode functions
```go
// Record total EURC revenue for a quarter. totalRevenue = micro-EURC integer string.
// One allocation per period — immutable after write.
RecordRevenueAllocation(ctx, period, totalRevenue)
    → txID string

// Read back a revenue allocation (evaluate, no endorsement).
GetRevenueAllocation(ctx, period)
    → RevenueAllocation

// Record a single EURC payout.  Enforces MiCA Art.71 consent gate internally.
// paymentRef = Stripe charge ID or on-chain tx hash.
RecordDistribution(ctx, holderHash, amount, period, paymentRef)
    → txID string

// Return all payout records for a holder (evaluate). Used for MiCA statements.
GetDistributionHistory(ctx, holderHash)
    → []DistributionRecord

// Returns true if holder has active distribution consent (evaluate).
VerifyHolderConsent(ctx, holderHash)
    → bool

// Write or update MiCA Art.71 distribution consent.
// signatureTxHash = channel-1 AdES txID (required when granting).
RecordHolderConsent(ctx, holderHash, granted, signatureTxHash)
    → txID string
```

**Key invariants for channel 5:**
- Amounts are stored as micro-EURC integer strings (1 EURC = 1_000_000) — never floats
- holderHash = SHA3-256(salt + holderAddress.Bytes()) — never a raw Polygon address
- RecordDistribution re-checks consent atomically — no distribution without MiCA consent
- Revenue allocations are immutable once written (one per period)
- This channel contains NO health data — it is purely a financial audit ledger

## Hashing
- Algorithm: SHA3-256 (`golang.org/x/crypto/sha3`)
- Salt: per-userID, stored in HSM (not on-chain)
- Pattern: SHA3_256(salt + userID)
- All hash inputs validated as 64 lowercase hex chars before acceptance
