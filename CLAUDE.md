# #nobordershealthcare — Project Constitution for Claude Code

## What this project is
Cross-border emergency health record system. Patient-controlled wallet-first architecture.
EU MDR Class IIa pathway. GDPR Art.9 by design. Pre-seed stage, Hospital da Luz pilot.

## Architecture summary
@docs/architecture.md

## ABSOLUTE RULES — never violate these
- NEVER store patient health data in cleartext anywhere outside the iOS device
- NEVER log PII (names, DOB, national IDs) — only SHA3-256(userID) and SHA3-256(docID) in logs
- NEVER use RxNorm for EU-facing code — use ATC (Anatomical Therapeutic Chemical) codes
- NEVER use generative AI in the clinical coding path — deterministic token mapping only
- NEVER store the token→cassandra_key mapping on disk — Redis RAM only, TTL enforced
- ALL encryption must be AES-256 minimum; key exchange via Kyber-1024 (NIST ML-KEM)
- ALL inter-service communication must use mTLS
- ALL blockchain writes contain only hashes — never content, never paths, never URLs
- AdES signature records NEVER stored in same silo as health data — always Fabric channel 1
- Legal vault uses SEPARATE AES key from eHR vault (keychain tag com.noborders.legal.key vs com.noborders.vault.key)

## Tech stack decisions (final, do not suggest alternatives)
- iOS: Swift 5.9+, SwiftUI, CryptoKit, CoreML, Secure Enclave APIs
- Backend services: Go 1.22+ (performance-critical) or Node.js 20 LTS (API services)
- Smart contracts: Hyperledger Fabric 2.5 chaincode in Go
- Database: ScyllaDB (Cassandra-compatible CQL) — NOT PostgreSQL, NOT MongoDB
- Token store: Redis 7+ with Lua scripting — persistence DISABLED (no AOF, no RDB)
- Object store: MinIO (S3-compatible) — EU-only buckets
- Container: Docker + Kubernetes (k8s) with Istio service mesh
- IaC: Terraform for infrastructure, Helm for k8s manifests
- CI/CD: GitHub Actions with Sigstore/cosign image signing

## Clinical standards (mandatory for all health data)
- Diagnoses: ICD-10-CM / ICD-10-GM
- Lab values: LOINC codes (e.g. HbA1c = LOINC 4548-4)
- Clinical concepts: SNOMED CT
- Medications: ATC codes (e.g. Lisinopril = ATC C09AA03, Metformin = ATC A10BA02)
- Data model: openEHR Compositions + HL7 FHIR R4 API
- Patient summary: IPS (International Patient Summary) profile

## Security non-negotiables
- TLS 1.3 minimum, no TLS 1.2 fallback
- JWT TTL: 15 minutes max
- Client certs rotate every 24h (mTLS)
- Admin operations require FIDO2 hardware key (YubiKey) — no TOTP, no SMS OTP
- Redis ACL: no CONFIG, no SLAVEOF, no DEBUG commands from application
- All Docker images signed with cosign before deploy — unsigned = rejected

## Hashing standard
- Algorithm: SHA3-256 (`golang.org/x/crypto/sha3`) — NEVER `crypto/sha256`
- All hash inputs: validated as 64 lowercase hex chars before acceptance
- Pattern: `SHA3_256(per-user-salt + userID)`
- Salt: stored in HSM, never on-chain

### Protocol-mandated SHA-256 exceptions (do NOT change these)
The following uses of SHA-256 are REQUIRED by external standards and have NO
SHA3 alternative — they are explicitly accepted and must not be flagged:
1. **Apple ECIES (iOS)** — `SecKeyCreateEncryptedData` / `SecKeyCreateDecryptedData`
   with `.eciesEncryptionCofactorX963SHA256AESGCM` or
   `.eciesEncryptionCofactorVariableIVX963SHA256AESGCM`.
   The Security.framework does not provide a SHA3 variant.
   Files: `VaultManager.swift`, `LegalVaultManager.swift`
2. **PKCE / RFC 7636** — `S256` code_challenge = `BASE64URL(SHA256(code_verifier))`.
   The BankID / OAuth 2.0 spec mandates SHA-256; no alternative is defined.
   File: `BankIDClient.swift`
CI gate (`security-gate-ios-sha2`) excludes `eciesEncryption` and `BankIDClient`.

## What NOT to generate
- No SQL databases for health data
- No cleartext health data in any log, metric, or trace
- No hardcoded secrets or API keys — use Vault / k8s secrets
- No monolithic services — each function is its own service
- No RxNorm codes in any EU-facing output
- No generative AI calls in the clinical coding pipeline

## Storage silos (5 total — see docs/architecture.md for full schema)
1. iOS Secure Enclave — eHR vault    (key: com.noborders.vault.key)
2. iOS Secure Enclave — Legal vault  (key: com.noborders.legal.key — SEPARATE)
3. ScyllaDB cluster                  (AES-256-GCM, hash keys only)
4. IPFS + Shamir K=3/N=7             (P2P resilience, device recovery)
5. Hyperledger Fabric (3 channels)   (hashes only — never content)
   - channel 1: signatures  (AdES records)
   - channel 2: consent-audit  (GDPR Art.7 lifecycle)
   - channel 3: access-audit   (GDPR Art.15 access log)

## Project structure
```
/ios          — Swift iOS wallet app
/backend      — Go/Node.js microservices
  /anonymizer   — core token factory service (most critical)
  /gatekeeper   — auth + smart contract verification
  /normalization — openEHR + LOINC/SNOMED mapping engine
/contracts              — Hyperledger Fabric chaincode (access control)
/contracts/channel1-signatures  — Fabric channel 1: AdES signature records
/contracts/channel2-consent     — Fabric channel 2: consent-audit
/contracts/channel3-access      — Fabric channel 3: access-audit
/infra        — Kubernetes manifests + Terraform
/docs         — architecture docs (referenced by CLAUDE.md files)
```

## Build order (follow this sequence)
1. /contracts — smart contract access control logic (defines the data model)
2. /backend/anonymizer — the core security innovation
3. /backend/gatekeeper — auth gateway
4. /backend/normalization — FHIR/openEHR mapping engine
5. /infra — k8s + Terraform
6. /ios — wallet app (depends on backend API contracts)

## Session startup checklist
When starting a new Claude Code session, run:
```
/memory          # check what Claude already knows
cat CLAUDE.md    # confirm constitution loaded
```
