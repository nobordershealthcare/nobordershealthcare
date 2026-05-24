package fabric

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"time"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/hyperledger/fabric-gateway/pkg/identity"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

// AccessResult is the decoded response from the CheckAccess chaincode function.
type AccessResult struct {
	Allowed bool     `json:"allowed"`
	Role    string   `json:"role"`
	Scope   []string `json:"scope"`
}

// Client wraps the Fabric Gateway with fail-closed access control semantics.
// It holds the underlying *client.Gateway so callers can obtain a *client.Network
// for any channel — used by ConsentWatcher to subscribe to channel-2 events.
type Client struct {
	gw       *client.Gateway // kept alive; Close() is the caller's responsibility
	contract *client.Contract
	timeout  time.Duration
}

// Config groups the connection parameters for the Fabric peer.
type Config struct {
	Endpoint    string
	MSPID       string
	CertPEM     []byte
	KeyPEM      []byte
	TLSCACert   []byte
	ChannelName string
	Chaincode   string
	Timeout     time.Duration
}

func New(cfg Config) (*Client, error) {
	id, err := identity.NewX509Identity(cfg.MSPID, mustParseCert(cfg.CertPEM))
	if err != nil {
		return nil, fmt.Errorf("fabric identity: %w", err)
	}

	sign, err := identity.NewPrivateKeySign(mustParseKey(cfg.KeyPEM))
	if err != nil {
		return nil, fmt.Errorf("fabric signer: %w", err)
	}

	tlsCACreds, err := tlsCredsFromPEM(cfg.TLSCACert)
	if err != nil {
		return nil, fmt.Errorf("fabric tls: %w", err)
	}

	conn, err := grpc.NewClient(cfg.Endpoint, grpc.WithTransportCredentials(tlsCACreds))
	if err != nil {
		return nil, fmt.Errorf("fabric grpc dial: %w", err)
	}

	gw, err := client.Connect(id, client.WithSign(sign), client.WithClientConnection(conn))
	if err != nil {
		return nil, fmt.Errorf("fabric gateway connect: %w", err)
	}

	network := gw.GetNetwork(cfg.ChannelName)
	contract := network.GetContract(cfg.Chaincode)

	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = 500 * time.Millisecond
	}

	return &Client{gw: gw, contract: contract, timeout: timeout}, nil
}

// GetNetwork returns a *client.Network for the named channel. Callers use this
// to create a ConsentWatcher for channel 2 without establishing a new connection.
func (c *Client) GetNetwork(channelName string) *client.Network {
	return c.gw.GetNetwork(channelName)
}

// Close tears down the underlying gateway connection. Call this once on shutdown.
func (c *Client) Close() {
	c.gw.Close()
}

// CheckAccess queries the chaincode with hashed requester and document IDs.
//
// Fail-closed contract — this function NEVER returns (true, nil) unless the
// chaincode explicitly grants access. Every ambiguous state becomes a denial:
//
//   - Timeout         → (false, err) — caller must return 403
//   - Network error   → (false, err) — caller must return 403
//   - Chaincode error → (false, err) — caller must return 403
//   - allowed=false   → (false, nil) — caller must return 403
//
// hashedRequesterID and hashedDocID must be 64-char lowercase hex strings
// (SHA3-256 output). No PII is passed to the chaincode.
func (c *Client) CheckAccess(ctx context.Context, hashedRequesterID, hashedDocID string) (AccessResult, error) {
	if err := validateHash(hashedRequesterID); err != nil {
		return AccessResult{}, fmt.Errorf("invalid hashedRequesterID: %w", err)
	}
	if err := validateHash(hashedDocID); err != nil {
		return AccessResult{}, fmt.Errorf("invalid hashedDocID: %w", err)
	}

	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	resultBytes, err := c.contract.EvaluateTransaction("CheckAccess", hashedRequesterID, hashedDocID)
	if err != nil {
		// Timeout and all network/chaincode errors land here. Fail closed.
		return AccessResult{}, fmt.Errorf("chaincode CheckAccess: %w", err)
	}

	var result AccessResult
	if err := json.Unmarshal(resultBytes, &result); err != nil {
		return AccessResult{}, fmt.Errorf("decode CheckAccess response: %w", err)
	}

	if !result.Allowed {
		return AccessResult{}, errors.New("access denied by smart contract")
	}
	return result, nil
}

// validateHash enforces the 64-char lowercase hex invariant before any hash
// reaches the chaincode. Rejects anything that could be a raw ID or path.
func validateHash(h string) error {
	if len(h) != 64 {
		return fmt.Errorf("expected 64 hex chars, got %d", len(h))
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return fmt.Errorf("non-lowercase-hex character: %q", c)
		}
	}
	return nil
}

func tlsCredsFromPEM(caPEM []byte) (credentials.TransportCredentials, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("no valid certs in Fabric TLS CA PEM")
	}
	return credentials.NewTLS(&tls.Config{
		RootCAs:    pool,
		MinVersion: tls.VersionTLS13,
	}), nil
}

func mustParseCert(certPEM []byte) *x509.Certificate {
	block, _ := pem.Decode(certPEM)
	if block == nil {
		panic("fabric: no PEM block in cert")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		panic(fmt.Sprintf("fabric: parse cert: %v", err))
	}
	return cert
}

func mustParseKey(keyPEM []byte) interface{} {
	block, _ := pem.Decode(keyPEM)
	if block == nil {
		panic("fabric: no PEM block in key")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		panic(fmt.Sprintf("fabric: parse key: %v", err))
	}
	return key
}
