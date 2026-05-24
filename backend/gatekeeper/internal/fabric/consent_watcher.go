// consent_watcher.go — Fabric channel-2 event subscriber that mirrors consent
// revocations to Redis so the physician-view scan handler can gate access
// without round-tripping to the blockchain on every request.
//
// Redis key contract (enforced by this file — do not write these keys elsewhere):
//
//	SET  revoke:{userIdHash}                    no TTL — written on ConsentRevoked
//	DEL  revoke:{userIdHash}                           — written on ConsentGranted
//	SET  fabric:checkpoint:{chaincode}  uint64  no TTL — last processed block number
//
// Checkpoint semantics:
//
//	On startup the watcher reads fabric:checkpoint:{chaincode} from Redis.
//	If the key exists, it resumes from blockNumber+1 — replaying only blocks
//	the current Redis instance has not yet processed.  If the key is absent
//	(fresh Redis instance, first-ever run) the watcher starts from block 0.
//
//	The checkpoint key and the revoke keys share the same Redis instance.
//	When Redis restarts both are lost together, so starting from block 0 and
//	replaying the full chain is always safe: the rebuild re-derives the exact
//	same revoke key set that existed before the restart.
//
//	The checkpoint is written AFTER each event is handled in Redis, so a crash
//	mid-block causes at-most-once re-delivery of that block's events on the
//	next restart — SET/DEL are idempotent, so re-processing is safe.

package fabric

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/redis/go-redis/v9"
)

const (
	// revokeKeyPrefix is the Redis key namespace checked by the physician-view
	// scan handler: EXISTS revoke:{sha3(sub)}.
	revokeKeyPrefix = "revoke:"

	// checkpointKeyPrefix stores the last block number successfully processed
	// by this watcher instance: fabric:checkpoint:{chaincode}.
	checkpointKeyPrefix = "fabric:checkpoint:"

	// Fabric chaincode event names emitted by channel2-consent/consent.go.
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
// All Redis operations use the context passed to Run(), which is cancelled on
// graceful shutdown before the HTTP server drains.
type ConsentWatcher struct {
	network   *client.Network
	chaincode string
	redis     *redis.Client
}

// NewConsentWatcher returns a ConsentWatcher connected to the given Fabric network
// (expected to be channel "consent-audit") and the shared Redis client.
//
// chaincode is the name of the chaincode deployed on that channel (typically
// "consent-audit").
func NewConsentWatcher(network *client.Network, chaincode string, redisClient *redis.Client) *ConsentWatcher {
	return &ConsentWatcher{
		network:   network,
		chaincode: chaincode,
		redis:     redisClient,
	}
}

// Run starts the event subscription loop. It blocks until ctx is cancelled.
// On transient errors (peer restart, network blip) it retries with a 10-second
// back-off.
//
// Typical call site in main():
//
//	go func() {
//	    if err := watcher.Run(ctx); err != nil && ctx.Err() == nil {
//	        slog.Error("consent watcher exited", "err", err)
//	        os.Exit(1)
//	    }
//	}()
func (w *ConsentWatcher) Run(ctx context.Context) error {
	slog.Info("consent watcher starting", "chaincode", w.chaincode)
	for {
		if err := w.subscribeAndProcess(ctx); err != nil {
			if ctx.Err() != nil {
				return ctx.Err() // graceful shutdown
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

// subscribeAndProcess reads the checkpoint, opens a ChaincodeEvents stream from
// that block, and drains it until ctx is cancelled or the stream closes.
func (w *ConsentWatcher) subscribeAndProcess(ctx context.Context) error {
	startBlock := w.readCheckpoint(ctx)

	events, err := w.network.ChaincodeEvents(ctx, w.chaincode,
		client.WithStartBlock(startBlock),
	)
	if err != nil {
		return fmt.Errorf("ChaincodeEvents subscribe: %w", err)
	}

	slog.Info("consent watcher subscribed",
		"chaincode", w.chaincode,
		"startBlock", startBlock,
	)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case event, ok := <-events:
			if !ok {
				return fmt.Errorf("chaincode event channel closed unexpectedly")
			}
			w.handleEvent(ctx, event)
			// Checkpoint is saved after the Redis operation so that a crash
			// between handleEvent and saveCheckpoint causes re-delivery of the
			// block on the next restart.  SET/DEL are idempotent so this is safe.
			w.saveCheckpoint(ctx, event.BlockNumber)
		}
	}
}

// readCheckpoint returns the block number to start from.
// If a checkpoint exists in Redis, returns checkpoint+1 (next unprocessed block).
// If no checkpoint exists (fresh Redis or first run), returns 0 (genesis).
func (w *ConsentWatcher) readCheckpoint(ctx context.Context) uint64 {
	key := checkpointKeyPrefix + w.chaincode
	val, err := w.redis.Get(ctx, key).Result()
	if err != nil {
		// redis.Nil means key not found — start from genesis.
		// Any other error: also start from genesis (conservative, always correct).
		if err != redis.Nil {
			slog.Warn("consent watcher: checkpoint read error — starting from block 0",
				"err", err,
			)
		}
		return 0
	}
	block, err := strconv.ParseUint(val, 10, 64)
	if err != nil {
		slog.Warn("consent watcher: checkpoint value malformed — starting from block 0",
			"value", val,
			"err", err,
		)
		return 0
	}
	slog.Info("consent watcher: resuming from checkpoint", "block", block+1)
	return block + 1
}

// saveCheckpoint writes the last successfully processed block number to Redis.
// Failure is non-fatal: the next restart falls back to the previous checkpoint
// (or block 0), which re-processes some events idempotently rather than missing any.
func (w *ConsentWatcher) saveCheckpoint(ctx context.Context, blockNumber uint64) {
	key := checkpointKeyPrefix + w.chaincode
	if err := w.redis.Set(ctx, key, strconv.FormatUint(blockNumber, 10), 0).Err(); err != nil {
		slog.Warn("consent watcher: checkpoint write failed — next restart may re-process blocks",
			"block", blockNumber,
			"err", err,
		)
	}
}

// handleEvent routes a single ChaincodeEvent to the appropriate Redis operation.
// Unknown event names are silently ignored to stay forward-compatible with future
// chaincode additions.
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

	// userIdHash must be SHA3-256 output: exactly 64 lowercase hex chars.
	// Reject anything shorter or longer — this is the last line before a hash
	// reaches a Redis key that gates medical record access.
	if len(payload.UserIdHash) != 64 {
		slog.Warn("consent watcher: event has invalid userIdHash length — dropping",
			"eventName", event.EventName,
			"length", len(payload.UserIdHash),
			"block", event.BlockNumber,
		)
		return
	}

	revokeKey := revokeKeyPrefix + payload.UserIdHash

	switch event.EventName {
	case eventConsentRevoked:
		// SET with no TTL — the revoke key must persist until the patient
		// explicitly re-grants consent (ConsentGranted event).  Redis is
		// memory-only; the checkpoint + block-0 fallback provide recovery.
		if err := w.redis.Set(ctx, revokeKey, "1", 0).Err(); err != nil {
			slog.Error("consent watcher: Redis SET failed for revoke key",
				"userIdHash", payload.UserIdHash,
				"consentType", payload.ConsentType,
				"block", event.BlockNumber,
				"err", err,
			)
			return
		}
		slog.Info("consent watcher: revoke key set",
			"userIdHash", payload.UserIdHash,
			"consentType", payload.ConsentType,
			"block", event.BlockNumber,
		)

	case eventConsentGranted:
		// DEL is idempotent — safe to call even when the key does not exist
		// (e.g. during replay of an initial grant with no prior revocation).
		deleted, err := w.redis.Del(ctx, revokeKey).Result()
		if err != nil {
			slog.Error("consent watcher: Redis DEL failed for revoke key",
				"userIdHash", payload.UserIdHash,
				"consentType", payload.ConsentType,
				"block", event.BlockNumber,
				"err", err,
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

	default:
		// Forward-compatible: ignore unknown event names.
	}
}
