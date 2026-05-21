# Gatekeeper Service — Module Context

## Language: Go 1.22+

## What this does
Auth + authorization decision point. Only service that sees plaintext userID —
for <100ms, then immediately hashes it. Never stores plaintext downstream.

## Auth flows
1. Patient: BankID/eIDAS → OIDC → JWT + hash(userID)
2. Emergency QR: patient-signed scope token → verify Ed25519 → hash(userID)
3. Enterprise: SMART-on-FHIR → OAuth2 PKCE → JWT
4. Admin: FIDO2 WebAuthn + YubiKey → JWT (admin scope)

## CRITICAL: plaintext userID handling

Go strings are immutable values — reassigning characters into a `string` does NOT
overwrite the backing memory. The only reliably zeroable type is `[]byte`.

```go
// Accept as []byte so the caller never holds a string copy.
// Salt is fetched while buf is live; both are zeroed in defer.
func (g *Gatekeeper) AuthenticateAndHash(plainUserID []byte) (string, error) {
    salt, err := g.hsm.GetUserSalt(plainUserID)
    if err != nil {
        return "", err
    }
    buf := make([]byte, len(salt)+len(plainUserID))
    copy(buf, salt)
    copy(buf[len(salt):], plainUserID)
    defer func() {
        for i := range buf        { buf[i] = 0 }
        for i := range salt       { salt[i] = 0 }
        for i := range plainUserID { plainUserID[i] = 0 }
        runtime.KeepAlive(buf)        // prevent compiler eliding the zeroing write
        runtime.KeepAlive(salt)
        runtime.KeepAlive(plainUserID)
    }()
    h := sha3.New256()             // golang.org/x/crypto/sha3
    h.Write(buf)
    digest := h.Sum(nil)
    result := hex.EncodeToString(digest)
    if len(result) != 64 {
        return "", errors.New("hash output length invariant violated")
    }
    return result, nil
}
// plainUserID NEVER logged, NEVER passed to any other service
```

Imports required: `golang.org/x/crypto/sha3`, `encoding/hex`, `runtime`, `errors`.

## JWT specification
```json
{
  "sub": "sha3_256(salt+userID)",   // hash only, never plaintext
  "role": "er_doctor",
  "scope": ["allergies", "medications", "diagnoses"],
  "iat": 1716000000,
  "exp": 1716000900,               // 15 min max — non-negotiable
  "jti": "UUID v4"                 // prevents replay attacks
}
```
Signed with Ed25519. Algorithm header is hardcoded — no algorithm confusion possible.
Reject any token where header.alg != "EdDSA".

## JWT jti replay protection
Each jti is stored in Redis as a SET member with TTL = JWT expiry window (15 min).
On every verify: SETNX the jti key. If the key already exists → 401 replay attack.
This prevents a stolen-but-valid token from being used more than once.

Redis key pattern: `jti:{jti_uuid}` — value is `1`, TTL is remaining token lifetime.
Redis ACL for gatekeeper: SETNX + EXPIRE only on the `jti:*` key prefix.

## Smart contract check (every request)
```go
result, err := g.fabricClient.CheckAccess(hashedRequesterID, hashedDocID)
if err != nil || !result.Allowed {
    return 403, "access denied"
}
// Pass result.Role and result.Scope to anonymizer
```

## What to pass to anonymizer
- hash(userID) — never plaintext
- hash(docID) — from client request
- verified_role — from smart contract
- verified_scope — what the role can see

## What this service MUST NOT do
- MUST NOT log plaintext userID even at DEBUG level
- MUST NOT cache plaintext userID between requests
- MUST NOT accept JWT with alg:none or RS256 (only EdDSA)
- MUST NOT forward request if smart contract check fails
