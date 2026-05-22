# Architecture Reference

## Core innovation: double-indirection tokenization
```
Smart contract  →  hash(userID)/hash(docID) only [on-chain, no PII]
Gatekeeper      →  verifies access, issues session_token
Anonymizer      →  session_token → ephemeral UUID (Redis RAM, TTL 60-300s)
                   ephemeral UUID → cassandra_row_key (in-memory map ONLY)
ScyllaDB        →  cassandra_row_key → AES-256 encrypted blob
MinIO           →  pre-signed URL, TTL 120s, single-use
```

## 5 Storage Silos

| # | Silo | Contents | Encryption key | Offline? |
|---|------|----------|----------------|---------|
| 1 | iOS Secure Enclave — eHR vault | Health records (openEHR/FHIR) | `com.noborders.vault.key` (SE-wrapped) | ✓ primary |
| 2 | iOS Secure Enclave — Legal vault | Consent records, proxies, DPAs, signature records | `com.noborders.legal.key` (SE-wrapped, SEPARATE) | ✓ primary |
| 3 | ScyllaDB cluster | AES-256-GCM encrypted eHR blobs (hash keys only) | Per-patient key from Vault | Backup |
| 4 | IPFS + Shamir K=3/N=7 | Encrypted device-recovery shards | Shamir shares | P2P resilience |
| 5 | Hyperledger Fabric (3 channels) | Hashes only — see channel schema below | N/A (immutable ledger) | Append-only |

**Critical separation invariant:** eHR vault key (`com.noborders.vault.key`) and Legal vault key
(`com.noborders.legal.key`) are distinct Keychain items backed by separate Secure Enclave key pairs.
A compromise of one key MUST NOT expose data from the other silo.

## Hyperledger Fabric — 3 Channels

### Channel 1: `signatures`
Stores AdES (Advanced Electronic Signature) records — immutable, legally binding.

```
World-state key:  SIG~{documentHash}
```

| Field | Type | Description |
|-------|------|-------------|
| documentHash | SHA3-256 hex | Hash of the signed document |
| signerPubKeyHash | SHA3-256 hex | Hash of signer's Ed25519 public key DER |
| signature | base64url | Ed25519 raw signature bytes |
| identityProvider | string | "bankid-se" / "bankid-no" / "eid-pt" |
| identityVerifiedAt | int64 | Unix seconds — when BankID/eID step-up occurred |
| legalBasis | []string | GDPR Art. references, e.g. ["Art.6(1)(a)", "Art.9(2)(a)"] |
| documentType | string | "consent" / "healthcare_proxy" / "dpa" / "ehr_access" |
| jurisdictions | []string | ISO 3166-1 alpha-2, e.g. ["SE", "PT", "DE"] |
| recordedAt | int64 | Fabric tx timestamp (GetTxTimestamp) |
| txID | string | Fabric transaction ID |

Chaincode functions: `RecordAdESSignature`, `VerifyAdESSignature`

### Channel 2: `consent-audit`
GDPR Art.7 consent lifecycle — every grant and revocation is an immutable ledger entry.

```
World-state key:  CONSENT~{userIdHash}~{consentType}~{txID}
```

| Field | Type | Description |
|-------|------|-------------|
| userIdHash | SHA3-256 hex | SHA3-256(salt+userID) |
| consentType | string | "ehr_access" / "research" / "insurance" / "emergency" |
| event | string | "granted" / "revoked" |
| expiresAt | int64 | Unix seconds; 0 = indefinite |
| signatureTxHash | string | Channel 1 txID of the AdES signature for this consent |
| recordedAt | int64 | Fabric tx timestamp |
| txID | string | Fabric transaction ID |

Chaincode functions: `RecordConsentGrant`, `RecordConsentRevoke`, `GetConsentHistory`

### Channel 3: `access-audit`
Every actual eHR data read is logged — separate from permission grants (channel 2).
Required for GDPR Art.15 patient right-of-access responses.

```
World-state key:  ACCESS~{patientIdHash}~{txID}
```

| Field | Type | Description |
|-------|------|-------------|
| patientIdHash | SHA3-256 hex | Record owner |
| accessorIdHash | SHA3-256 hex | Who accessed the record |
| accessorType | string | "er_doctor" / "insurer" / "researcher" / "guardian" |
| licenseHash | SHA3-256 hex | Hash of accessor's professional licence DER |
| accessScope | []string | FHIR resource types accessed, e.g. ["Observation","Condition"] |
| duration | int32 | Seconds the record was held open |
| consentRef | string | Channel 2 txID of the governing consent record |
| signatureRef | string | Channel 1 txID of the accessor's session signature |
| recordedAt | int64 | Fabric tx timestamp |
| txID | string | Fabric transaction ID |

Chaincode functions: `RecordEHRAccess`, `GetAccessHistory`

## Access roles (smart contract enforced)
| Role       | Scope                    | Auth method         |
|------------|--------------------------|---------------------|
| patient    | full owner               | BankID + biometric  |
| guardian   | delegated by patient     | patient signature   |
| er_doctor  | IPS emergency subset     | QR scope token      |
| insurer    | claim-relevant only      | smart contract grant|
| researcher | anonymized aggregate     | smart contract grant|
| admin      | force-assemble (2-person)| FIDO2 + HSM sign    |

## Clinical standards
- Diagnoses: ICD-10-CM / ICD-10-GM
- Lab values: LOINC (e.g. HbA1c = 4548-4)
- Clinical concepts: SNOMED CT
- Medications: ATC (Lisinopril = C09AA03, Metformin = A10BA02)
- Data model: openEHR Compositions + HL7 FHIR R4 API
- Patient summary: IPS (International Patient Summary)

## Key security properties
- No persistent token→docID mapping anywhere on disk
- Redis cluster: no AOF, no RDB, memory-only
- Anonymizer pods: immutable, replaced every 10k requests or 1h
- All access events: hash(who)+hash(what) on Hyperledger Fabric channel 3
- AdES signature records: channel 1 ONLY — never co-located with eHR data
- Kyber-1024 hybrid TLS (X25519 + Kyber) against HNDL attacks
- mTLS between ALL internal services
- eHR vault key ≠ Legal vault key — separate SE key pairs, separate Keychain items
