package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
	"golang.org/x/crypto/sha3"
)

// AccessControlContract implements all chaincode functions for NoBorders access control.
// All blockchain writes contain only SHA3-256 hashes — never PII, paths, or content.
type AccessControlContract struct {
	contractapi.Contract
}

var validRoles = map[string]bool{
	"patient":    true,
	"guardian":   true,
	"er_doctor":  true,
	"insurer":    true,
	"researcher": true,
	"admin":      true,
}

// validateHash rejects any input that is not a valid 64-character lowercase SHA3-256 hex string.
// SHA3-256 produces 32 bytes → 64 hex characters; uppercase letters are rejected.
func validateHash(h string) error {
	if len(h) != 64 {
		return ErrInvalidHash
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return ErrInvalidHash
		}
	}
	return nil
}

func validateRole(role string) error {
	if !validRoles[role] {
		return ErrInvalidRole
	}
	return nil
}

// callerCertHash computes the SHA3-256 digest of the submitting client's X.509 DER bytes.
func callerCertHash(ctx contractapi.TransactionContextInterface) (string, error) {
	cert, err := ctx.GetClientIdentity().GetX509Certificate()
	if err != nil {
		return "", fmt.Errorf("cannot read caller certificate: %w", err)
	}
	h := sha3.New256()
	h.Write(cert.Raw)
	return hex.EncodeToString(h.Sum(nil)), nil
}

// assertAdmin returns ErrNotAdmin unless the caller holds role="admin" in their enrollment cert.
func assertAdmin(ctx contractapi.TransactionContextInterface) error {
	if err := ctx.GetClientIdentity().AssertAttributeValue("role", "admin"); err != nil {
		return ErrNotAdmin
	}
	return nil
}

func getAccessRecord(ctx contractapi.TransactionContextInterface, userHash, docHash, role string) (*AccessRecord, error) {
	key, err := ctx.GetStub().CreateCompositeKey("ACCESS", []string{userHash, docHash, role})
	if err != nil {
		return nil, fmt.Errorf("cannot create composite key: %w", err)
	}
	data, err := ctx.GetStub().GetState(key)
	if err != nil {
		return nil, fmt.Errorf("world state read failed: %w", err)
	}
	if data == nil {
		return nil, ErrRecordNotFound
	}
	var rec AccessRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, fmt.Errorf("cannot unmarshal access record: %w", err)
	}
	return &rec, nil
}

func putAccessRecord(ctx contractapi.TransactionContextInterface, rec *AccessRecord) error {
	key, err := ctx.GetStub().CreateCompositeKey("ACCESS", []string{rec.UserHash, rec.DocHash, rec.Role})
	if err != nil {
		return fmt.Errorf("cannot create composite key: %w", err)
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("cannot marshal access record: %w", err)
	}
	return ctx.GetStub().PutState(key, data)
}

// emitAccessEvent writes an AuditEntry within the current transaction.
// It must always be called from inside the same transaction as the triggering operation —
// Fabric's read-write set semantics guarantee both writes commit or both roll back together.
func emitAccessEvent(ctx contractapi.TransactionContextInterface, entry *AuditEntry) error {
	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	entry.TxID = ctx.GetStub().GetTxID()
	entry.Timestamp = ts.Seconds

	// Composite key AUDIT~docHash~txID enables partial-key range queries by docHash.
	key, err := ctx.GetStub().CreateCompositeKey("AUDIT", []string{entry.DocHash, entry.TxID})
	if err != nil {
		return fmt.Errorf("cannot create audit key: %w", err)
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("cannot marshal audit entry: %w", err)
	}
	return ctx.GetStub().PutState(key, data)
}

// ─── Public chaincode functions ──────────────────────────────────────────────

// RegisterRecord writes a (hash(userID), hash(docID)) ownership tuple to world state.
// The submitting client's certificate hash must equal userHash (self-registration only;
// admin registration goes through ForceAssemble).
func (c *AccessControlContract) RegisterRecord(ctx contractapi.TransactionContextInterface, userHash, docHash string) error {
	if err := validateHash(userHash); err != nil {
		return err
	}
	if err := validateHash(docHash); err != nil {
		return err
	}

	submitterHash, err := callerCertHash(ctx)
	if err != nil {
		return err
	}
	if submitterHash != userHash {
		return ErrNotOwner
	}

	existing, err := getAccessRecord(ctx, userHash, docHash, "patient")
	if err == nil && !existing.Revoked {
		return ErrRecordExists
	}

	rec := &AccessRecord{
		UserHash:  userHash,
		DocHash:   docHash,
		Role:      "patient",
		GrantedBy: userHash,
		Expiry:    0,
		Revoked:   false,
	}
	if err := putAccessRecord(ctx, rec); err != nil {
		return err
	}
	return emitAccessEvent(ctx, &AuditEntry{
		DocHash:   docHash,
		ActorHash: userHash,
		Role:      "patient",
		Operation: "RegisterRecord",
	})
}

// GrantAccess creates a delegated access grant for the given role.
// Only the record owner (submitter cert hash == userHash) may call this.
func (c *AccessControlContract) GrantAccess(ctx contractapi.TransactionContextInterface, userHash, docHash, role string, expiry int64) error {
	if err := validateHash(userHash); err != nil {
		return err
	}
	if err := validateHash(docHash); err != nil {
		return err
	}
	if err := validateRole(role); err != nil {
		return err
	}

	submitterHash, err := callerCertHash(ctx)
	if err != nil {
		return err
	}
	if submitterHash != userHash {
		return ErrNotOwner
	}

	existing, err := getAccessRecord(ctx, userHash, docHash, role)
	if err == nil && !existing.Revoked {
		return ErrRecordExists
	}

	rec := &AccessRecord{
		UserHash:  userHash,
		DocHash:   docHash,
		Role:      role,
		GrantedBy: userHash,
		Expiry:    expiry,
		Revoked:   false,
	}
	if err := putAccessRecord(ctx, rec); err != nil {
		return err
	}
	return emitAccessEvent(ctx, &AuditEntry{
		DocHash:   docHash,
		ActorHash: userHash,
		Role:      role,
		Operation: "GrantAccess",
	})
}

// RevokeAccess marks an access grant as revoked.
// The record owner or any admin may call this.
func (c *AccessControlContract) RevokeAccess(ctx contractapi.TransactionContextInterface, userHash, docHash, role string) error {
	if err := validateHash(userHash); err != nil {
		return err
	}
	if err := validateHash(docHash); err != nil {
		return err
	}
	if err := validateRole(role); err != nil {
		return err
	}

	submitterHash, err := callerCertHash(ctx)
	if err != nil {
		return err
	}
	isAdmin := assertAdmin(ctx) == nil
	if submitterHash != userHash && !isAdmin {
		return ErrNotOwner
	}

	rec, err := getAccessRecord(ctx, userHash, docHash, role)
	if err != nil {
		return err
	}
	if rec.Revoked {
		return ErrAccessRevoked
	}

	rec.Revoked = true
	if err := putAccessRecord(ctx, rec); err != nil {
		return err
	}
	return emitAccessEvent(ctx, &AuditEntry{
		DocHash:   docHash,
		ActorHash: submitterHash,
		Role:      role,
		Operation: "RevokeAccess",
	})
}

// VerifyAccess checks whether callerHash holds a valid, non-revoked, non-expired grant
// for (docHash, role). An audit entry is written in the same transaction regardless of outcome.
// Expiry comparison uses GetTxTimestamp (deterministic across endorsing peers; never time.Now).
func (c *AccessControlContract) VerifyAccess(ctx contractapi.TransactionContextInterface, callerHash, docHash, role string) (bool, error) {
	if err := validateHash(callerHash); err != nil {
		return false, err
	}
	if err := validateHash(docHash); err != nil {
		return false, err
	}
	if err := validateRole(role); err != nil {
		return false, err
	}

	rec, err := getAccessRecord(ctx, callerHash, docHash, role)
	if err != nil {
		// No record is a silent denial — nothing to audit (no docHash context on the ledger).
		if err == ErrRecordNotFound {
			return false, nil
		}
		return false, err
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return false, fmt.Errorf("cannot get tx timestamp: %w", err)
	}

	var operation string
	allowed := true
	switch {
	case rec.Revoked:
		operation = "VerifyAccess:denied:revoked"
		allowed = false
	case rec.Expiry > 0 && rec.Expiry < ts.Seconds:
		operation = "VerifyAccess:denied:expired"
		allowed = false
	default:
		operation = "VerifyAccess:granted"
	}

	if err := emitAccessEvent(ctx, &AuditEntry{
		DocHash:   docHash,
		ActorHash: callerHash,
		Role:      role,
		Operation: operation,
	}); err != nil {
		return false, err
	}
	return allowed, nil
}

// ForceAssemble creates or overwrites an access grant using 2-of-2 admin co-signature.
// The submitting admin's certificate hash is computed on-chain; cosignerAdminHash is the
// SHA3-256 of a second distinct admin's certificate DER, recorded in the audit log.
func (c *AccessControlContract) ForceAssemble(ctx contractapi.TransactionContextInterface, userHash, docHash, role string, expiry int64, cosignerAdminHash string) error {
	if err := validateHash(userHash); err != nil {
		return err
	}
	if err := validateHash(docHash); err != nil {
		return err
	}
	if err := validateRole(role); err != nil {
		return err
	}
	if err := validateHash(cosignerAdminHash); err != nil {
		return err
	}
	if err := assertAdmin(ctx); err != nil {
		return err
	}

	submitterHash, err := callerCertHash(ctx)
	if err != nil {
		return err
	}
	if submitterHash == cosignerAdminHash {
		return ErrSameAdmin
	}

	rec := &AccessRecord{
		UserHash:  userHash,
		DocHash:   docHash,
		Role:      role,
		GrantedBy: submitterHash,
		Expiry:    expiry,
		Revoked:   false,
	}
	if err := putAccessRecord(ctx, rec); err != nil {
		return err
	}
	return emitAccessEvent(ctx, &AuditEntry{
		DocHash:    docHash,
		ActorHash:  userHash,
		Role:       role,
		Operation:  "ForceAssemble",
		Admin1Hash: submitterHash,
		Admin2Hash: cosignerAdminHash,
	})
}

// QueryAuditTrail returns all audit entries for the given docHash, ordered by txID
// (lexicographic within the docHash composite key prefix — insertion order on LevelDB).
func (c *AccessControlContract) QueryAuditTrail(ctx contractapi.TransactionContextInterface, docHash string) ([]*AuditEntry, error) {
	if err := validateHash(docHash); err != nil {
		return nil, err
	}

	iter, err := ctx.GetStub().GetStateByPartialCompositeKey("AUDIT", []string{docHash})
	if err != nil {
		return nil, fmt.Errorf("audit trail query failed: %w", err)
	}
	defer iter.Close()

	var entries []*AuditEntry
	for iter.HasNext() {
		result, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("audit trail iteration error: %w", err)
		}
		var entry AuditEntry
		if err := json.Unmarshal(result.Value, &entry); err != nil {
			return nil, fmt.Errorf("cannot unmarshal audit entry: %w", err)
		}
		entries = append(entries, &entry)
	}
	return entries, nil
}

// ReassignRole admin-force-reassigns a user from oldRole to newRole in a single atomic transaction.
// Requires the same 2-of-2 admin co-signature as ForceAssemble. The old grant is revoked and the
// new grant is created in the same read-write set; both roll back together if anything fails.
func (c *AccessControlContract) ReassignRole(ctx contractapi.TransactionContextInterface, userHash, docHash, oldRole, newRole, cosignerAdminHash string) error {
	if err := validateHash(userHash); err != nil {
		return err
	}
	if err := validateHash(docHash); err != nil {
		return err
	}
	if err := validateRole(oldRole); err != nil {
		return err
	}
	if err := validateRole(newRole); err != nil {
		return err
	}
	if err := validateHash(cosignerAdminHash); err != nil {
		return err
	}
	if err := assertAdmin(ctx); err != nil {
		return err
	}

	submitterHash, err := callerCertHash(ctx)
	if err != nil {
		return err
	}
	if submitterHash == cosignerAdminHash {
		return ErrSameAdmin
	}

	oldRec, err := getAccessRecord(ctx, userHash, docHash, oldRole)
	if err != nil {
		return err
	}

	// Revoke the old grant (tombstone — world state key is preserved for audit continuity).
	oldRec.Revoked = true
	if err := putAccessRecord(ctx, oldRec); err != nil {
		return err
	}

	newRec := &AccessRecord{
		UserHash:  userHash,
		DocHash:   docHash,
		Role:      newRole,
		GrantedBy: submitterHash,
		Expiry:    oldRec.Expiry, // preserve original expiry
		Revoked:   false,
	}
	if err := putAccessRecord(ctx, newRec); err != nil {
		return err
	}

	return emitAccessEvent(ctx, &AuditEntry{
		DocHash:    docHash,
		ActorHash:  userHash,
		Role:       newRole,
		Operation:  "ReassignRole",
		Admin1Hash: submitterHash,
		Admin2Hash: cosignerAdminHash,
		OldRole:    oldRole,
		NewRole:    newRole,
	})
}
