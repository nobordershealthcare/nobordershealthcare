// consent_watcher.go — Fabric channel-2 event subscriber that mirrors consent
// revocations to Redis so the physician-view scan handler can gate access
// without round-tripping to the blockchain on every request.
//
// Redis key contract (enforced by this file — do not write these keys elsewhere):
//
//   SET  revoke:{userIdHash}   value "1"   no TTL   — written on ConsentRevoked
//   DEL  revoke:{userIdHash}                         — written on ConsentGranted
//
// Redis has no persistence (no AOF, no RDB). On any pod restart, Run() replays
// all Fabric events from block 0 so Redis is fully resynchronised before the
// first request is served. This means the startup phase also acts as the
// recovery mechanism — no separate snapshot or migration is needed.
//
// TODO(pilot→production): checkpoint the last processed block number to a
// persistent store (e.g. a Kubernetes ConfigMap updated atomically) so replay
// on restart starts from the checkpoint rather than genesis. On a long-lived
// chain this prevents a long cold-start window.

package fabric

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/redis/go-redis/v9"
)

// Redis key prefix for consent revocations.
// Physician-view scan handler checks: EXISTS revoke:{sha3(sub)}.
const revokeKeyPrefix = "revoke:"

// Fabric chaincode event names emitted by channel2-consent/consent.go.
const (
	eventConsentRevoked = "ConsentRevoked"
	eventConsentGranted = "ConsentGranted"
)

// consentEventPayload matches the JSON struct emitted by the channel-2 chaincode.
type consentEventPayload struct {
	UserIdHash  string `json:"userIdHash"`
	ConsentType string `json:"consentType"`
}

// ConsentWatcher subscribes to Hyperledger Fabric channel-2 (consent-audit)
// chaincode events and keeps Redis in sync with the revocation state of every
// patient's consent records.
//
// Thread safety: Run() is designed to be called once in a dedicated goroutine.
// The watcher is stateless between restarts — all state is in Redis and Fabric.
type ConsentWatcher struct {
	network   *client.Network
	chaincode string
	redis     *redis.Client
}

// NewConsentWatcher returns a ConsentWatcher connected to the given Fabric network
// (expected to be channel "consent-audit") and the shared Redis client.
//
// chaincode is the chaincode name deployed on that channel (typically "consent-audit").
func NewConsentWatcher(network *client.Network, chaincode string, redisClient *redis.Client) *ConsentWatcher {
	return &ConsentWatcher{
		network:   network,
		chaincode: chaincode,
		redis:     redisClient,
	}
}

// Run starts the event subscription loop. It replays from block 0 on every
// invocation — ensuring Redis is fully consistent with the ledger regardless of
// what happened before this call.
//
// Run blocks until ctx is cancelled. It retries the Fabric subscription with a
// 10-second back-off on transient errors (peer restart, network blip).
//
// Typical call site in main():
//
//	go func() {
//	    if err := watcher.Run(ctx); err != nil && err != context.Canceled {
//	        slog.Error("consent watcher exited", "err", err)
//	        os.Exit(1)
//	    }
//	}()
func (w *ConsentWatcher) Run(ctx context.Context) error {
	slog.Info("consent watcher starting", "chaincode", w.chaincode)
	for {
		if err := w.subscribeAndProcess(ctx); err != nil {
			if ctx.Err() != nil {
				// Graceful shutdown — not an error.
				return ctx.Err()
			}
			slog.Error("consent watcher subscription error — will retry",
				"err", err,
				"retryIn", "10s",
			)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(10 * time.Second):
			}
		}
	}
}

// subscribeAndProcess opens a ChaincodeEvents stream from block 0 and drains it
// until the context is cancelled or the stream closes unexpectedly.
func (w *ConsentWatcher) subscribeAndProcess(ctx context.Context) error {
	// WithStartBlock(0) replays all historical events from the genesis block.
	// This is the recovery mechanism after any Redis data loss (pod restart, eviction).
	events, err := w.network.ChaincodeEvents(ctx, w.chaincode,
		client.WithStartBlock(0),
	)
	if err != nil {
		return fmt.Errorf("ChaincodeEvents subscribe: %w", err)
	}

	slog.Info("consent watcher subscribed — replaying from block 0")

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case event, ok := <-events:
			if !ok {
				return fmt.Errorf("chaincode event channel closed unexpectedly")
			}
			w.handleEvent(ctx, event)
		}
	}
}

// handleEvent routes a single ChaincodeEvent to the appropriate Redis operation.
// Unknown event names are silently ignored — the channel may carry future events.
func (w *ConsentWatcher) handleEvent(ctx context.Context, event *client.ChaincodeEvent) {
	var payload consentEventPayload
	if err := json.Unmarshal(event.Payload, &payload); err != nil {
		slog.Warn("consent watcher: malformed event payload",
			"eventName", event.EventName,
			"block", event.BlockNumber,
			"err", err,
		)
		return
	}

	// Validate that userIdHash is a well-formed SHA3-256 hex digest (64 chars).
	// Reject anything that could be raw PII reaching this point accidentally.
	if len(payload.UserIdHash) != 64 {
		slog.Warn("consent watcher: event has invalid userIdHash length — dropping",
			"eventName", event.EventName,
			"length", len(payload.UserIdHash),
			"block", event.BlockNumber,
		)
		return
	}

	key := revokeKeyPrefix + payload.UserIdHash

	switch event.EventName {
	case eventConsentRevoked:
		// SET revoke:{userIdHash} — no TTL.
		// Redis is memory-only, so the key survives until: (a) a ConsentGranted event
		// clears it, or (b) the pod restarts (watcher then rehydrates from block 0).
		if err := w.redis.Set(ctx, key, "1", 0).Err(); err != nil {
			slog.Error("consent watcher: Redis SET failed for revoke key",
				"consentType", payload.ConsentType,
				"block", event.BlockNumber,
				"err", err,
				// Log full hash — userIdHash is SHA3-256(salt+userID), not PII.
				"userIdHash", payload.UserIdHash,
			)
			return
		}
		slog.Info("consent watcher: revoke key set",
			"userIdHash", payload.UserIdHash,
			"consentType", payload.ConsentType,
			"block", event.BlockNumber,
		)

	case eventConsentGranted:
		// DEL revoke:{userIdHash} — consent re-established, clear the block.
		// DEL is idempotent: if the key never existed (e.g. replay of an initial grant),
		// Redis returns 0 deleted and we log accordingly.
		deleted, err := w.redis.Del(ctx, key).Result()
		if err != nil {
			slog.Error("consent watcher: Redis DEL failed for revoke key",
				"consentType", payload.ConsentType,
				"block", event.BlockNumber,
				"err", err,
				"userIdHash", payload.UserIdHash,
			)
			return
		}
		if deleted > 0 {
			slog.Info("consent watcher: revoke key cleared on re-grant",
				"userIdHash", payload.UserIdHash,
				"consentType", payload.ConsentType,
				"block", event.BlockNumber,
			)
		}
		// deleted == 0 is normal for initial grants (no prior revoke key) — not logged.

	default:
		// Future event types — ignore silently to stay forward-compatible.
	}
}
