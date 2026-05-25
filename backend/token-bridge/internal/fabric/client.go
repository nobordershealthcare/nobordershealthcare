// Package fabric wraps the Hyperledger Fabric Gateway client for channel5-token.
// All public methods accept/return plain Go types; JSON marshalling happens here.
package fabric

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/hyperledger/fabric-gateway/pkg/identity"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

const (
	channelName  = "token-distribution"
	contractName = "channel5-token"
)

// RevenueAllocation mirrors the on-chain struct for JSON decoding.
type RevenueAllocation struct {
	Period       string `json:"period"`
	TotalRevenue string `json:"totalRevenue"`
	AllocatedAt  int64  `json:"allocatedAt"`
	TxID         string `json:"txID"`
}

// DistributionRecord mirrors the on-chain struct for JSON decoding.
type DistributionRecord struct {
	HolderHash string `json:"holderHash"`
	Amount     string `json:"amount"`
	Period     string `json:"period"`
	PaymentRef string `json:"paymentRef"`
	RecordedAt int64  `json:"recordedAt"`
	TxID       string `json:"txID"`
}

// Client is a thin wrapper around the Fabric Gateway contract handle.
type Client struct {
	gw       *client.Gateway
	contract *client.Contract
}

// Config groups the connection parameters read from environment / mounted secrets.
type Config struct {
	// PeerEndpoint is the peer gRPC address, e.g. "peer0.org1.example.com:7051"
	PeerEndpoint string
	// GatewayPeerTLSCert is the PEM file path for the peer's TLS cert.
	GatewayPeerTLSCert string
	// MSP ID for the org, e.g. "Org1MSP"
	MSPID string
	// CertPEM is the path to the client identity certificate.
	CertPEM string
	// KeyPEM is the path to the client private key.
	KeyPEM string
}

// New dials the Fabric peer and returns a ready-to-use Client.
func New(cfg Config) (*Client, error) {
	tlsCert, err := loadTLSCert(cfg.GatewayPeerTLSCert)
	if err != nil {
		return nil, fmt.Errorf("load peer TLS cert: %w", err)
	}

	conn, err := grpc.NewClient(cfg.PeerEndpoint,
		grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{
			RootCAs:    tlsCert,
			MinVersion: tls.VersionTLS13,
		})),
	)
	if err != nil {
		return nil, fmt.Errorf("grpc dial %s: %w", cfg.PeerEndpoint, err)
	}

	id, err := loadIdentity(cfg.MSPID, cfg.CertPEM)
	if err != nil {
		return nil, fmt.Errorf("load identity: %w", err)
	}

	sign, err := loadSigner(cfg.KeyPEM)
	if err != nil {
		return nil, fmt.Errorf("load signer: %w", err)
	}

	gw, err := client.Connect(id,
		client.WithSign(sign),
		client.WithClientConnection(conn),
		client.WithEvaluateTimeout(10*time.Second),
		client.WithEndorseTimeout(30*time.Second),
		client.WithSubmitTimeout(30*time.Second),
		client.WithCommitStatusTimeout(60*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("fabric gateway connect: %w", err)
	}

	contract := gw.GetNetwork(channelName).GetContract(contractName)
	return &Client{gw: gw, contract: contract}, nil
}

// Close releases the gateway connection.
func (c *Client) Close() { c.gw.Close() }

// RecordRevenueAllocation submits a revenue allocation for a quarter.
func (c *Client) RecordRevenueAllocation(period, totalRevenueMicroEURC string) (string, error) {
	result, err := c.contract.SubmitTransaction("RecordRevenueAllocation", period, totalRevenueMicroEURC)
	if err != nil {
		return "", fmt.Errorf("RecordRevenueAllocation(%s): %w", period, err)
	}
	return string(result), nil
}

// GetRevenueAllocation reads the allocation record for a period (evaluate, no endorsement).
func (c *Client) GetRevenueAllocation(period string) (*RevenueAllocation, error) {
	result, err := c.contract.EvaluateTransaction("GetRevenueAllocation", period)
	if err != nil {
		return nil, fmt.Errorf("GetRevenueAllocation(%s): %w", period, err)
	}
	var rec RevenueAllocation
	if err := json.Unmarshal(result, &rec); err != nil {
		return nil, fmt.Errorf("unmarshal RevenueAllocation: %w", err)
	}
	return &rec, nil
}

// RecordDistribution submits a payout record.
// The chaincode enforces the consent gate — this call will fail if consent is absent.
func (c *Client) RecordDistribution(holderHash, amountMicroEURC, period, paymentRef string) (string, error) {
	result, err := c.contract.SubmitTransaction("RecordDistribution",
		holderHash, amountMicroEURC, period, paymentRef)
	if err != nil {
		return "", fmt.Errorf("RecordDistribution(%s…): %w", holderHash[:8], err)
	}
	return string(result), nil
}

// GetDistributionHistory returns all payout records for a holder (evaluate).
func (c *Client) GetDistributionHistory(holderHash string) ([]*DistributionRecord, error) {
	result, err := c.contract.EvaluateTransaction("GetDistributionHistory", holderHash)
	if err != nil {
		return nil, fmt.Errorf("GetDistributionHistory(%s…): %w", holderHash[:8], err)
	}
	var records []*DistributionRecord
	if err := json.Unmarshal(result, &records); err != nil {
		return nil, fmt.Errorf("unmarshal DistributionHistory: %w", err)
	}
	if records == nil {
		records = []*DistributionRecord{}
	}
	return records, nil
}

// VerifyHolderConsent evaluates the consent state for a holder (no write, no endorsement).
func (c *Client) VerifyHolderConsent(holderHash string) (bool, error) {
	result, err := c.contract.EvaluateTransaction("VerifyHolderConsent", holderHash)
	if err != nil {
		return false, fmt.Errorf("VerifyHolderConsent(%s…): %w", holderHash[:8], err)
	}
	// Chaincode returns "true" or "false" as JSON booleans.
	var ok bool
	if err := json.Unmarshal(result, &ok); err != nil {
		return false, fmt.Errorf("unmarshal VerifyHolderConsent result: %w", err)
	}
	return ok, nil
}

// RecordHolderConsent submits a consent grant or revocation to channel 5.
// signatureTxHash must be the channel-1 AdES txID; pass empty string for revocations.
func (c *Client) RecordHolderConsent(holderHash string, granted bool, signatureTxHash string) (string, error) {
	grantedStr := "false"
	if granted {
		grantedStr = "true"
	}
	result, err := c.contract.SubmitTransaction("RecordHolderConsent",
		holderHash, grantedStr, signatureTxHash)
	if err != nil {
		return "", fmt.Errorf("RecordHolderConsent(%s…): %w", holderHash[:8], err)
	}
	return string(result), nil
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

func loadTLSCert(certPath string) (*x509.CertPool, error) {
	pem, err := os.ReadFile(certPath)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("no valid certificates in %s", certPath)
	}
	return pool, nil
}

func loadIdentity(mspID, certPath string) (identity.Identity, error) {
	pem, err := os.ReadFile(certPath)
	if err != nil {
		return nil, err
	}
	cert, err := identity.CertificateFromPEM(pem)
	if err != nil {
		return nil, fmt.Errorf("parse cert: %w", err)
	}
	return identity.NewX509Identity(mspID, cert)
}

func loadSigner(keyPath string) (identity.Sign, error) {
	pem, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, err
	}
	key, err := identity.PrivateKeyFromPEM(pem)
	if err != nil {
		return nil, fmt.Errorf("parse key: %w", err)
	}
	return identity.NewPrivateKeySign(key)
}
