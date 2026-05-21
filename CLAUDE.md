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

## What NOT to generate
- No SQL databases for health data
- No cleartext health data in any log, metric, or trace
- No hardcoded secrets or API keys — use Vault / k8s secrets
- No monolithic services — each function is its own service
- No RxNorm codes in any EU-facing output
- No generative AI calls in the clinical coding pipeline

## Project structure
```
/ios          — Swift iOS wallet app
/backend      — Go/Node.js microservices
  /anonymizer   — core token factory service (most critical)
  /gatekeeper   — auth + smart contract verification
  /normalization — openEHR + LOINC/SNOMED mapping engine
/contracts    — Hyperledger Fabric chaincode
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
