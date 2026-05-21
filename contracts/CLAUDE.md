# Hyperledger Fabric Chaincode — Module Context

## Language: Go 1.22+  |  Fabric: 2.5 LTS

## What goes ON-CHAIN (only this, nothing else)
- hash(userID) → []AccessRecord{hash(docID), role, scope, grantedAt, expiresAt}
- AccessEvent{hash(who), hash(docID), action, timestamp, result}
- ConsentRevocation{hash(userID), hash(docID), revokedAt}

## What NEVER goes on-chain
- Any plaintext, any health data, file paths, URLs, IP addresses
- Mapping between hash(docID) and storage location

## 7 chaincode functions to implement
```go
// 1. Patient grants role access to their docID
GrantAccess(ctx, hashedUserID, hashedDocID, role, scope, ttlSeconds)

// 2. Patient revokes access immediately
RevokeAccess(ctx, hashedUserID, hashedDocID, role)

// 3. Gatekeeper queries: is this access permitted?
CheckAccess(ctx, hashedRequesterID, hashedDocID) → (allowed bool, role, scope)

// 4. Anonymizer logs access event (fire-and-forget)
LogAccessEvent(ctx, hashedRequesterID, hashedDocID, action, result)

// 5. Patient requests GDPR Art.15 access log
GetAccessHistory(ctx, hashedUserID) → []AccessEvent

// 6. Admin force-reassign (requires 2 admin signatures)
AdminForceReassign(ctx, hashedUserID, newRole, admin1Sig, admin2Sig)

// 7. Admin force-assemble eHR (requires 2 admin signatures)
AdminForceAssemble(ctx, hashedUserID, admin1Sig, admin2Sig) → assemblyToken
```

## Endorsement policy
- Standard: 2-of-3 peer endorsement
- Admin operations: 3-of-3 + HSM signature verification
- No single point of authority

## Invariants (verify formally)
- User CANNOT escalate their own role
- Only patient can grant access to their own records
- AdminForceReassign requires BOTH admin signatures
- ConsentRevocation is immediate — no grace period
- AccessHistory is append-only — no delete function

## Hashing
- Algorithm: SHA3-256
- Salt: per-userID, stored in HSM (not on-chain)
- Pattern: SHA3_256(salt + userID)
