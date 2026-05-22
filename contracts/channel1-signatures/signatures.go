package main

import (
	"encoding/json"
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// SignaturesContract implements channel 1: AdES legally-binding signature records.
// INVARIANT: Every field written to world state is a hash, base64url string, or primitive.
// No PII, no health data, no file paths, no URLs may enter this contract.
type SignaturesContract struct {
	contractapi.Contract
}

// ─── Validation helpers ───────────────────────────────────────────────────────

func validateSigHash(h string) error {
	if len(h) != 64 {
		return fmt.Errorf("invalid hash: expected 64 lowercase hex chars, got %d", len(h))
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return fmt.Errorf("invalid hash: contains non-hex character '%c'", c)
		}
	}
	return nil
}

func validateIdentityProvider(provider string) error {
	if !validIdentityProviders[provider] {
		return fmt.Errorf("unknown identity provider %q", provider)
	}
	return nil
}

func validateDocumentType(docType string) error {
	if !validDocumentTypes[docType] {
		return fmt.Errorf("unknown document type %q", docType)
	}
	return nil
}

func validateJurisdictions(jurisdictions []string) error {
	if len(jurisdictions) == 0 {
		return fmt.Errorf("at least one jurisdiction is required")
	}
	for _, j := range jurisdictions {
		if len(j) != 2 {
			return fmt.Errorf("jurisdiction %q must be ISO 3166-1 alpha-2 (2 chars)", j)
		}
	}
	return nil
}

func validateLegalBasis(basis []string) error {
	if len(basis) == 0 {
		return fmt.Errorf("at least one legal basis is required (e.g. Art.6(1)(a))")
	}
	return nil
}

// ─── Storage helpers ──────────────────────────────────────────────────────────

func sigKey(ctx contractapi.TransactionContextInterface, documentHash string) (string, error) {
	return ctx.GetStub().CreateCompositeKey("SIG", []string{documentHash})
}

func getSignatureRecord(ctx contractapi.TransactionContextInterface, documentHash string) (*SignatureRecord, error) {
	key, err := sigKey(ctx, documentHash)
	if err != nil {
		return nil, fmt.Errorf("composite key error: %w", err)
	}
	data, err := ctx.GetStub().GetState(key)
	if err != nil {
		return nil, fmt.Errorf("world state read failed: %w", err)
	}
	if data == nil {
		return nil, fmt.Errorf("signature record not found for document %s", documentHash)
	}
	var rec SignatureRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, fmt.Errorf("cannot unmarshal signature record: %w", err)
	}
	return &rec, nil
}

func putSignatureRecord(ctx contractapi.TransactionContextInterface, rec *SignatureRecord) error {
	key, err := sigKey(ctx, rec.DocumentHash)
	if err != nil {
		return fmt.Errorf("composite key error: %w", err)
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("cannot marshal signature record: %w", err)
	}
	return ctx.GetStub().PutState(key, data)
}

// ─── Public chaincode functions ───────────────────────────────────────────────

// RecordAdESSignature writes an Advanced Electronic Signature record to channel 1.
//
// Called by the iOS app after BankID/eID step-up completes and the Ed25519 signature
// has been created locally in the Secure Enclave. The caller supplies:
//   - documentHash: SHA3-256 of the document bytes (computed on-device)
//   - signerPubKeyHash: SHA3-256 of the signer's Ed25519 public key DER
//   - signature: base64url-encoded raw Ed25519 signature (64 bytes → 88 base64url chars)
//   - identityProvider: one of the approved eID schemes
//   - identityVerifiedAt: Unix timestamp of the eID step-up event
//   - legalBasis: []string of applicable GDPR Article references
//   - documentType: document category
//   - jurisdictions: []string of ISO 3166-1 alpha-2 country codes
//
// Returns the Fabric transaction ID so it can be stored in the iOS Legal vault
// and referenced in channel 2 (consent-audit) as signatureTxHash.
//
// A document may only be signed once. To re-sign, the document must be updated
// (producing a new hash) and a new RecordAdESSignature call is required.
func (c *SignaturesContract) RecordAdESSignature(
	ctx contractapi.TransactionContextInterface,
	documentHash string,
	signerPubKeyHash string,
	signature string,
	identityProvider string,
	identityVerifiedAt int64,
	legalBasis []string,
	documentType string,
	jurisdictions []string,
) (string, error) {
	if err := validateSigHash(documentHash); err != nil {
		return "", fmt.Errorf("documentHash: %w", err)
	}
	if err := validateSigHash(signerPubKeyHash); err != nil {
		return "", fmt.Errorf("signerPubKeyHash: %w", err)
	}
	if len(signature) == 0 {
		return "", fmt.Errorf("signature must not be empty")
	}
	if err := validateIdentityProvider(identityProvider); err != nil {
		return "", err
	}
	if identityVerifiedAt <= 0 {
		return "", fmt.Errorf("identityVerifiedAt must be a positive Unix timestamp")
	}
	if err := validateLegalBasis(legalBasis); err != nil {
		return "", err
	}
	if err := validateDocumentType(documentType); err != nil {
		return "", err
	}
	if err := validateJurisdictions(jurisdictions); err != nil {
		return "", err
	}

	// Reject duplicates — a document hash is immutable after first signing.
	existing, err := getSignatureRecord(ctx, documentHash)
	if err == nil && existing != nil {
		return "", fmt.Errorf("signature already recorded for document %s (txID: %s)", documentHash, existing.TxID)
	}

	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return "", fmt.Errorf("cannot get tx timestamp: %w", err)
	}
	txID := ctx.GetStub().GetTxID()

	rec := &SignatureRecord{
		DocumentHash:       documentHash,
		SignerPubKeyHash:   signerPubKeyHash,
		Signature:          signature,
		IdentityProvider:   identityProvider,
		IdentityVerifiedAt: identityVerifiedAt,
		LegalBasis:         legalBasis,
		DocumentType:       documentType,
		Jurisdictions:      jurisdictions,
		RecordedAt:         ts.Seconds,
		TxID:               txID,
	}
	if err := putSignatureRecord(ctx, rec); err != nil {
		return "", err
	}
	return txID, nil
}

// VerifyAdESSignature retrieves the signature record for a given document hash.
// Returns the full SignatureRecord so the caller can verify the Ed25519 signature
// offline using the signer's public key (fetched separately from the DID registry).
//
// A not-found result is returned as (nil, nil) — the absence of a record is a
// legitimate state, not a chaincode error. The caller decides how to interpret it.
func (c *SignaturesContract) VerifyAdESSignature(
	ctx contractapi.TransactionContextInterface,
	documentHash string,
) (*SignatureRecord, error) {
	if err := validateSigHash(documentHash); err != nil {
		return nil, fmt.Errorf("documentHash: %w", err)
	}

	key, err := sigKey(ctx, documentHash)
	if err != nil {
		return nil, fmt.Errorf("composite key error: %w", err)
	}
	data, err := ctx.GetStub().GetState(key)
	if err != nil {
		return nil, fmt.Errorf("world state read failed: %w", err)
	}
	if data == nil {
		return nil, nil // not found — caller decides
	}
	var rec SignatureRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, fmt.Errorf("cannot unmarshal signature record: %w", err)
	}
	return &rec, nil
}
