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

## 3 Storage silos
1. iOS Secure Enclave vault — primary, offline-capable
2. ScyllaDB cluster — encrypted backup (hash keys, never plaintext)
3. IPFS + Shamir K=3/N=7 — P2P resilience, device recovery

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
- All access events: hash(who)+hash(what) on Hyperledger Fabric
- Kyber-1024 hybrid TLS (X25519 + Kyber) against HNDL attacks
- mTLS between ALL internal services
