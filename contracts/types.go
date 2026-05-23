package main

// AccessRecord is stored in world state under composite key ACCESS~userHash~docHash~role.
// Every field is a SHA3-256 hex string or a primitive — no PII is ever stored.
type AccessRecord struct {
	UserHash  string `json:"userHash"`
	DocHash   string `json:"docHash"`
	Role      string `json:"role"`
	GrantedBy string `json:"grantedBy"` // SHA3-256 of granting identity cert DER bytes
	Expiry    int64  `json:"expiry"`    // Unix seconds; 0 = perpetual
	Revoked   bool   `json:"revoked"`
}

// AuditEntry is stored under composite key AUDIT~docHash~txID.
// Admin1Hash, Admin2Hash, OldRole, NewRole are populated only for admin operations.
type AuditEntry struct {
	DocHash    string `json:"docHash"`
	ActorHash  string `json:"actorHash"`
	Role       string `json:"role"`
	Operation  string `json:"operation"`
	TxID       string `json:"txID"`
	Timestamp  int64  `json:"timestamp"`
	Admin1Hash string `json:"admin1Hash,omitempty"`
	Admin2Hash string `json:"admin2Hash,omitempty"`
	OldRole    string `json:"oldRole,omitempty"`
	NewRole    string `json:"newRole,omitempty"`
}

// AdminProposal is stored under composite key ADMIN_PROPOSAL~proposalID.
//
// Two-step admin co-signature flow:
//   Step 1 — Admin1 calls ProposeAdminAction:
//     * Chaincode verifies caller has role="admin" in their enrollment cert.
//     * Proposal is written to world state; proposalID = Fabric txID.
//     * Proposal expires after 24 hours (ProposalTTLSeconds).
//   Step 2 — Admin2 calls ApproveAdminAction(proposalID):
//     * Chaincode verifies caller has role="admin" in their enrollment cert.
//     * Chaincode verifies ApproverHash != ProposerHash (on-chain, not caller-supplied).
//     * If valid, the action is executed and Executed is set to true.
//
// Security invariant: both admin identities are computed from their X.509 certificate
// DER bytes via callerCertHash(ctx) — neither hash is accepted as a parameter.
type AdminProposal struct {
	ProposalID   string `json:"proposalID"`            // Fabric txID of the proposal tx
	ActionType   string `json:"actionType"`            // "ForceAssemble" or "ReassignRole"
	UserHash     string `json:"userHash"`
	DocHash      string `json:"docHash"`
	Role         string `json:"role"`
	NewRole      string `json:"newRole,omitempty"`     // only for ReassignRole
	Expiry       int64  `json:"expiry"`                // forwarded to the resulting AccessRecord
	ProposerHash string `json:"proposerHash"`          // computed on-chain, never supplied by caller
	ProposedAt   int64  `json:"proposedAt"`            // Fabric tx timestamp
	ExpiresAt    int64  `json:"expiresAt"`             // proposal auto-invalidates after 24h
	Executed     bool   `json:"executed"`
	ApproverHash string `json:"approverHash,omitempty"`
}

// ProposalTTLSeconds is the lifetime of an unexecuted AdminProposal.
// Proposals not approved within this window are rejected.
const ProposalTTLSeconds = int64(86400) // 24 hours
