// Package audit provides a fire-and-forget Hyperledger Fabric audit log
// for the normalization service.
//
// Every CDR write event is recorded on-chain as:
//
//	hash(who) + ":" + hash(what)
//
// No plaintext identifiers, no content, no paths — only hashes.
// The Fabric call is made in a goroutine so it never blocks the write path.
// If the Fabric call fails, it is logged as WARN — the CDR write already
// succeeded and is the source of truth.
package audit

import (
	"encoding/hex"
	"fmt"
	"log/slog"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"golang.org/x/crypto/sha3"
)

// FabricAuditor records normalization events to the Hyperledger Fabric audit chain.
type FabricAuditor struct {
	contract *client.Contract
	log      *slog.Logger
}

// NewFabricAuditor creates an auditor using the given Fabric contract handle.
func NewFabricAuditor(contract *client.Contract, log *slog.Logger) *FabricAuditor {
	return &FabricAuditor{contract: contract, log: log}
}

// RecordNormalization submits a normalization event to the audit chain.
// Called as a goroutine — errors are logged as WARN, never fatal.
//
//	requesterHash = SHA3-256(userID) of whoever triggered the ingestion
//	docHash       = SHA3-256(docID) of the document that was normalized
func (a *FabricAuditor) RecordNormalization(requesterHash, docHash string) {
	go func() {
		if err := a.submit(requesterHash, docHash); err != nil {
			// WARN only: the CDR write already succeeded. Fabric outage must
			// not roll back committed clinical data.
			a.log.Warn("fabric audit submit failed",
				"err", err,
				// Log only the first 8 chars of each hash — enough for correlation,
				// not enough to reconstruct PII.
				"requester_prefix", safePrefix(requesterHash),
				"doc_prefix", safePrefix(docHash),
			)
		}
	}()
}

func (a *FabricAuditor) submit(requesterHash, docHash string) error {
	// Build the on-chain event: SHA3-256(requesterHash + ":" + docHash).
	// This is a hash of hashes — doubly indirected, no PII on-chain.
	combined := requesterHash + ":" + docHash
	h := sha3.New256()
	h.Write([]byte(combined))
	eventHash := hex.EncodeToString(h.Sum(nil))

	_, err := a.contract.SubmitTransaction("RecordEvent",
		requesterHash, // on-chain: hash only
		docHash,       // on-chain: hash only
		eventHash,     // on-chain: combined hash for deduplication
		"normalization", // event type label
	)
	if err != nil {
		return fmt.Errorf("fabric SubmitTransaction: %w", err)
	}
	return nil
}

func safePrefix(hash string) string {
	if len(hash) >= 8 {
		return hash[:8] + "..."
	}
	return hash
}
