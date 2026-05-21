# iOS Wallet — Module Context

## What this module builds
The patient-controlled health wallet. This IS the primary product surface.

## Key iOS frameworks to use
- CryptoKit — AES-GCM encryption, Secure Enclave key operations
- LocalAuthentication — biometric + device passcode
- CoreML — on-device xLM inference (GGUF quantized models)
- DeviceCheck + DCAppAttestService — jailbreak detection + server attestation
- Security framework — keychain operations, SecRandomCopyBytes for CSPRNG
- PJSIP or Linphone SDK — SIP client for telemedicine
- Network framework — DoH (DNS over HTTPS), QUIC/HTTP3

## Module structure
```
/ios
  /Core
    VaultManager.swift       — AES-256 + Kyber-1024 key management
    SecureEnclaveKey.swift   — private key in Secure Enclave, never exported
    BiometricAuth.swift      — continuous behavioral auth + FaceID/TouchID
    AttestationService.swift — DCAppAttestService integration
  /eHR
    HealthRecord.swift       — openEHR composition model
    FHIRMapper.swift         — maps local data to FHIR R4 resources
    IPS.swift                — International Patient Summary builder
    EmergencyCard.swift      — offline emergency data (no network required)
  /QR
    QRGenerator.swift        — generates scoped session QR
    ScopeManager.swift       — patient configures what ER doctor can see
  /Identity
    DIDWallet.swift          — W3C DID with multiple HealthID credentials
    BankIDClient.swift       — BankID integration (Nordic + eIDAS)
    KeyManager.swift         — Ed25519 signing, Kyber-1024 KEM
  /Translation
    xLMEngine.swift          — CoreML inference, terminology mapping ONLY
    TerminologyMapper.swift  — LOINC/SNOMED/ATC display label translation
  /Telemedicine
    SIPClient.swift          — PJSIP wrapper, SRTP+ZRTP media
    CallView.swift           — telemedicine UI
  /Backup
    ShamirShard.swift        — Shamir K=3/N=7 shard generation
    IPFSClient.swift         — libp2p shard distribution

## CRITICAL security rules
- Master key MUST be in Secure Enclave (kSecAttrTokenIDSecureEnclave)
- Use SecRandomCopyBytes — NEVER Swift.random for crypto
- SecureZeroMemory: zero all plaintext buffers within 200ms of use
- DCAppAttestService: attest every sensitive API call, reject on jailbreak
- Screenshot detection: UIScreen.capturedDidChangeNotification → blur view

## xLM rules (CRITICAL)
The xLM translates DISPLAY LABELS only — NEVER clinical codes.
ICD-10, SNOMED, LOINC, ATC codes come from TerminologyMapper.swift lookup tables.
Example: xLM("HbA1c", targetLang: "de") → "HbA1c" (label only, not the value)
xLM does NOT receive raw medical documents to interpret.

## Emergency QR specification
- QR encodes: JWT scope token, patient Ed25519 signed, 15min TTL
- Scope: patient-configurable subset of IPS fields (allergies, medications, diagnoses)
- Lock screen widget: no device unlock required to display QR
- Offline: works without network — token is self-contained and verifiable offline
- Revocation: patient taps "revoke" → new token issued, old one invalidated
