// Package polygon subscribes to NBHC token Transfer events on Polygon PoS.
// Each new recipient address is hashed (SHA3-256) and forwarded to the Fabric
// ledger and the distribution calculator via the NewHolder channel.
package polygon

import (
	"context"
	"encoding/hex"
	"fmt"
	"log"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"golang.org/x/crypto/sha3"
)

// HolderEvent is emitted for every new recipient seen on a Transfer event.
type HolderEvent struct {
	Address    common.Address
	HolderHash string // SHA3-256(salt+address.Bytes()) — 64 hex chars
	TokensMoved *big.Int
}

// Listener subscribes to NBHC token Transfer events via a Polygon WebSocket RPC.
type Listener struct {
	client       *ethclient.Client
	contractAddr common.Address
	contractABI  abi.ABI
	holderSalt   []byte // fetched from Vault at startup; never logged
	NewHolder    chan HolderEvent
}

// NewListener dials the Polygon WebSocket endpoint and parses the NBHC token ABI.
// holderSalt must be the raw salt bytes for SHA3-256(salt+address) hashing.
func NewListener(rpcURL string, contractAddr common.Address, holderSalt []byte) (*Listener, error) {
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("polygon dial %s: %w", rpcURL, err)
	}

	parsedABI, err := abi.JSON(strings.NewReader(NBHCTokenABI))
	if err != nil {
		return nil, fmt.Errorf("parse NBHC token ABI: %w", err)
	}

	return &Listener{
		client:       client,
		contractAddr: contractAddr,
		contractABI:  parsedABI,
		holderSalt:   holderSalt,
		NewHolder:    make(chan HolderEvent, 256),
	}, nil
}

// Run subscribes to Transfer events and forwards HolderEvents until ctx is cancelled.
// Exits cleanly on ctx cancellation; the caller is responsible for draining NewHolder.
func (l *Listener) Run(ctx context.Context) error {
	query := ethereum.FilterQuery{
		Addresses: []common.Address{l.contractAddr},
		Topics:    [][]common.Hash{{l.contractABI.Events["Transfer"].ID}},
	}

	logCh := make(chan ethtypes.Log, 256)
	sub, err := l.client.SubscribeFilterLogs(ctx, query, logCh)
	if err != nil {
		return fmt.Errorf("polygon subscribe: %w", err)
	}
	defer sub.Unsubscribe()

	log.Printf("token-bridge/polygon: subscribed to Transfer events on %s", l.contractAddr.Hex())

	for {
		select {
		case <-ctx.Done():
			return nil

		case err := <-sub.Err():
			return fmt.Errorf("polygon subscription error: %w", err)

		case vLog := <-logCh:
			evt, err := l.parseTransfer(vLog)
			if err != nil {
				log.Printf("token-bridge/polygon: skip malformed log tx=%s: %v", vLog.TxHash.Hex(), err)
				continue
			}
			// Skip mint-from-zero (contract minting events); address(0) is not a holder.
			if evt.Address == (common.Address{}) {
				continue
			}
			select {
			case l.NewHolder <- *evt:
			default:
				// Channel full — log and drop rather than block the subscription.
				log.Printf("token-bridge/polygon: WARNING NewHolder channel full, dropping event for %s", evt.HolderHash[:8])
			}
		}
	}
}

// GetBalance returns the current NBHC token balance for an address at the latest block.
func (l *Listener) GetBalance(ctx context.Context, addr common.Address) (*big.Int, error) {
	callData, err := l.contractABI.Pack("balanceOf", addr)
	if err != nil {
		return nil, fmt.Errorf("pack balanceOf: %w", err)
	}
	result, err := l.client.CallContract(ctx, ethereum.CallMsg{
		To:   &l.contractAddr,
		Data: callData,
	}, nil)
	if err != nil {
		return nil, fmt.Errorf("call balanceOf: %w", err)
	}
	var balance *big.Int
	if err := l.contractABI.UnpackIntoInterface(&balance, "balanceOf", result); err != nil {
		return nil, fmt.Errorf("unpack balanceOf: %w", err)
	}
	return balance, nil
}

// GetTotalSupply returns the current total token supply.
func (l *Listener) GetTotalSupply(ctx context.Context) (*big.Int, error) {
	callData, err := l.contractABI.Pack("totalSupply")
	if err != nil {
		return nil, fmt.Errorf("pack totalSupply: %w", err)
	}
	result, err := l.client.CallContract(ctx, ethereum.CallMsg{
		To:   &l.contractAddr,
		Data: callData,
	}, nil)
	if err != nil {
		return nil, fmt.Errorf("call totalSupply: %w", err)
	}
	var supply *big.Int
	if err := l.contractABI.UnpackIntoInterface(&supply, "totalSupply", result); err != nil {
		return nil, fmt.Errorf("unpack totalSupply: %w", err)
	}
	return supply, nil
}

// GetAllHoldersFromLogs replays Transfer events from startBlock to "latest" and
// returns the deduplicated set of recipient addresses.
// Used once at startup to sync pre-existing holders to the Fabric ledger.
func (l *Listener) GetAllHoldersFromLogs(ctx context.Context, startBlock uint64) ([]common.Address, error) {
	query := ethereum.FilterQuery{
		FromBlock: new(big.Int).SetUint64(startBlock),
		Addresses: []common.Address{l.contractAddr},
		Topics:    [][]common.Hash{{l.contractABI.Events["Transfer"].ID}},
	}
	logs, err := l.client.FilterLogs(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("filter logs: %w", err)
	}

	seen := make(map[common.Address]struct{}, len(logs))
	for _, vLog := range logs {
		evt, err := l.parseTransfer(vLog)
		if err != nil || evt.Address == (common.Address{}) {
			continue
		}
		seen[evt.Address] = struct{}{}
	}

	holders := make([]common.Address, 0, len(seen))
	for addr := range seen {
		holders = append(holders, addr)
	}
	return holders, nil
}

// HashHolder computes SHA3-256(salt ++ address.Bytes()) and returns a 64-char hex string.
// The salt is the per-instance secret from Vault; never logged or stored on-chain.
func (l *Listener) HashHolder(addr common.Address) string {
	h := sha3.New256()
	h.Write(l.holderSalt)
	h.Write(addr.Bytes())
	return hex.EncodeToString(h.Sum(nil))
}

// ─── Internal ─────────────────────────────────────────────────────────────────

func (l *Listener) parseTransfer(vLog ethtypes.Log) (*HolderEvent, error) {
	// Transfer(address indexed from, address indexed to, uint256 value)
	// Topics[0] = event signature hash
	// Topics[1] = from (indexed)
	// Topics[2] = to   (indexed)
	if len(vLog.Topics) < 3 {
		return nil, fmt.Errorf("unexpected topic count %d", len(vLog.Topics))
	}
	to := common.HexToAddress(vLog.Topics[2].Hex())

	// The non-indexed "value" field is in vLog.Data.
	values, err := l.contractABI.Unpack("Transfer", vLog.Data)
	if err != nil {
		return nil, fmt.Errorf("unpack Transfer data: %w", err)
	}
	value, ok := values[0].(*big.Int)
	if !ok {
		return nil, fmt.Errorf("unexpected type for Transfer.value")
	}

	return &HolderEvent{
		Address:     to,
		HolderHash:  l.HashHolder(to),
		TokensMoved: value,
	}, nil
}
