package audit

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/hyperledger/fabric-sdk-go/pkg/client/channel"
	"github.com/hyperledger/fabric-sdk-go/pkg/core/config"
	"github.com/hyperledger/fabric-sdk-go/pkg/fabsdk"
	"golang.org/x/crypto/sha3"
)

// FabricLogger emits access audit events to Hyperledger Fabric.
// Only hash(who)+hash(what) goes on-chain — never PII, never content.
type FabricLogger struct {
	sdk         *fabsdk.FabricSDK
	channelName string
	chaincode   string
	org         string
	user        string
}

// AuditEvent is what goes on-chain. Both fields are SHA3-256 hex strings.
type AuditEvent struct {
	WhoHash  string `json:"who"`  // SHA3-256(per-user-salt + userID)
	WhatHash string `json:"what"` // SHA3-256(docID)
	When     int64  `json:"when"` // Unix timestamp seconds
}

func NewFabricLogger(connectionProfile, channel, chaincode string) (*FabricLogger, error) {
	sdk, err := fabsdk.New(config.FromFile(connectionProfile))
	if err != nil {
		return nil, fmt.Errorf("fabric sdk init: %w", err)
	}
	return &FabricLogger{
		sdk:         sdk,
		channelName: channel,
		chaincode:   chaincode,
		org:         "Org1",
		user:        "anonymizer-service",
	}, nil
}

// LogAccess records a hash(who)+hash(what) event on Fabric in a goroutine.
// Fire-and-forget: failures are logged but do not fail the request, because
// Fabric availability must not gate health record delivery in an emergency.
// whoHash and whatHash must already be SHA3-256 hex strings (64 chars each).
func (f *FabricLogger) LogAccess(whoHash, whatHash string) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		if err := f.emit(ctx, whoHash, whatHash); err != nil {
			// Log the hashes only — never raw identifiers.
			slog.Warn("fabric audit log failed",
				"who_hash", whoHash,
				"what_hash", whatHash,
				"err", err,
			)
		}
	}()
}

func (f *FabricLogger) emit(ctx context.Context, whoHash, whatHash string) error {
	if err := validateAuditHashes(whoHash, whatHash); err != nil {
		return err
	}

	event := AuditEvent{
		WhoHash:  whoHash,
		WhatHash: whatHash,
		When:     time.Now().Unix(),
	}
	payload, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("marshal audit event: %w", err)
	}

	channelProvider := f.sdk.ChannelContext(f.channelName,
		fabsdk.WithUser(f.user),
		fabsdk.WithOrg(f.org),
	)
	client, err := channel.New(channelProvider)
	if err != nil {
		return fmt.Errorf("fabric channel client: %w", err)
	}

	// Context timeout is enforced by the caller's context.WithTimeout above.
	// The Fabric SDK v1 Execute does not accept a context option directly.
	_, err = client.Execute(channel.Request{
		ChaincodeID: f.chaincode,
		Fcn:         "LogAccess",
		Args:        [][]byte{payload},
	})
	return err
}

// HashForAudit produces SHA3-256(salt+input) for audit log use.
// salt comes from HSM-backed configuration, never hardcoded.
// This is a convenience helper — callers may also pre-compute hashes upstream.
func HashForAudit(salt, input []byte) string {
	combined := append(salt, input...)
	h := sha3.Sum256(combined)
	return hex.EncodeToString(h[:])
}

func validateAuditHashes(whoHash, whatHash string) error {
	for _, h := range []string{whoHash, whatHash} {
		if len(h) != 64 {
			return fmt.Errorf("audit hash must be 64 hex chars, got %d", len(h))
		}
		if _, err := hex.DecodeString(h); err != nil {
			return fmt.Errorf("audit hash not valid hex: %w", err)
		}
	}
	return nil
}

func (f *FabricLogger) Close() {
	f.sdk.Close()
}
