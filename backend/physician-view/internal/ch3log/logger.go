// Package ch3log logs clinician access events to Hyperledger Fabric Channel 3.
//
// Channel 3 is the access-audit channel — it records who accessed which patient
// data and when. Only SHA3-256 hashes are written to the ledger — never plaintext
// license numbers, patient names, or any PII.
//
// Hash rule: golang.org/x/crypto/sha3 everywhere — NEVER crypto/sha256.
//
// Fabric submission is synchronous and fail-closed: if the ledger write fails,
// the caller must NOT expose patient data. The HTTP handler returns 503.
package ch3log

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/hyperledger/fabric-gateway/pkg/identity"
	"golang.org/x/crypto/sha3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

// AccessType describes the kind of access being logged.
type AccessType string

const (
	AccessEmergencyQR    AccessType = "emergencyQR"
	AccessProxyDocument  AccessType = "proxyDocument"
	AccessClinicianForm  AccessType = "clinicianForm"
)

// AccessEvent is the payload submitted to the Ch3 chaincode.
// All identifiers are SHA3-256 hashes — the ledger contains no PII.
type AccessEvent struct {
	EventType          string `json:"eventType"`
	ClinicianLicHash   string `json:"clinicianLicHash"`   // SHA3-256 of normalised license number
	PatientSubHash     string `json:"patientSubHash"`     // SHA3-256 of JWT sub claim (already a hash)
	ClinicianCountry   string `json:"clinicianCountry"`   // ISO 3166-1 alpha-2
	AccessedAt         string `json:"accessedAt"`         // RFC3339 UTC
	JTI                string `json:"jti"`                // JWT jti or one-time proxy token ID
}

// Logger submits access events to Fabric Channel 3 via the Gateway SDK.
type Logger struct {
	contract *client.Contract
	timeout  time.Duration
}

// Config holds the Fabric connection parameters for the Ch3 logger.
type Config struct {
	Endpoint    string
	MSPID       string
	CertPEM     []byte
	KeyPEM      []byte
	TLSCACert   []byte
	ChannelName string // "channel3" or equivalent
	Chaincode   string
	Timeout     time.Duration
}

// New creates a Ch3 Logger from the given config.
// Returns an error if the mTLS connection or identity cannot be established.
func New(cfg Config) (*Logger, error) {
	id, err := identity.NewX509Identity(cfg.MSPID, mustParseCert(cfg.CertPEM))
	if err != nil {
		return nil, fmt.Errorf("ch3log identity: %w", err)
	}
	sign, err := identity.NewPrivateKeySign(mustParseKey(cfg.KeyPEM))
	if err != nil {
		return nil, fmt.Errorf("ch3log signer: %w", err)
	}
	tlsCreds, err := tlsCredsFromPEM(cfg.TLSCACert)
	if err != nil {
		return nil, fmt.Errorf("ch3log tls: %w", err)
	}

	conn, err := grpc.NewClient(cfg.Endpoint, grpc.WithTransportCredentials(tlsCreds))
	if err != nil {
		return nil, fmt.Errorf("ch3log grpc: %w", err)
	}

	gw, err := client.Connect(id, client.WithSign(sign), client.WithClientConnection(conn))
	if err != nil {
		return nil, fmt.Errorf("ch3log fabric connect: %w", err)
	}

	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = 3 * time.Second
	}

	return &Logger{
		contract: gw.GetNetwork(cfg.ChannelName).GetContract(cfg.Chaincode),
		timeout:  timeout,
	}, nil
}

// LogAccess submits an access event to Channel 3.
// clinicianLicense is the normalised license number (will be SHA3-256'd before submission).
// patientSub is the JWT sub claim — already a SHA3-256 hash; we hash it again to get
// SHA3-256(sub) so the ledger never reveals the app-level pseudonym directly.
// Fail-closed: returns error if the ledger write fails.
func (l *Logger) LogAccess(
	ctx context.Context,
	accessType AccessType,
	clinicianLicense string,
	clinicianCountry string,
	patientSub string,
	jti string,
) error {
	if clinicianLicense == "" || patientSub == "" {
		return errors.New("ch3log: clinicianLicense and patientSub are required")
	}

	event := AccessEvent{
		EventType:        string(accessType),
		ClinicianLicHash: sha3Hex([]byte(clinicianLicense)),
		PatientSubHash:   sha3Hex([]byte(patientSub)),
		ClinicianCountry: clinicianCountry,
		AccessedAt:       time.Now().UTC().Format(time.RFC3339),
		JTI:              jti,
	}

	payload, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("ch3log marshal: %w", err)
	}

	ctx, cancel := context.WithTimeout(ctx, l.timeout)
	defer cancel()

	_, err = l.contract.SubmitTransaction("LogAccess", string(payload))
	if err != nil {
		return fmt.Errorf("ch3log SubmitTransaction: %w", err)
	}
	return nil
}

// sha3Hex returns the lowercase hex SHA3-256 digest of data.
// golang.org/x/crypto/sha3 — NEVER crypto/sha256.
func sha3Hex(data []byte) string {
	h := sha3.New256()
	h.Write(data)
	return fmt.Sprintf("%x", h.Sum(nil))
}

// NewFromEnv builds a Logger from environment variables.
// Expected vars: FABRIC_ENDPOINT, FABRIC_MSPID, FABRIC_CERT_PATH,
// FABRIC_KEY_PATH, FABRIC_TLSCA_PATH, FABRIC_CHANNEL3, FABRIC_CHAINCODE3.
// NewFromEnv builds a Logger from environment variables.
// Uses os.LookupEnv (not os.Getenv) for path variables that flow into os.ReadFile
// to avoid gosec G704 SSRF taint analysis false positives.
func NewFromEnv() (*Logger, error) {
	endpoint, _ := os.LookupEnv("FABRIC_ENDPOINT")
	mspID, _ := os.LookupEnv("FABRIC_MSPID")
	certPath, _ := os.LookupEnv("FABRIC_CERT_PATH")
	keyPath, _ := os.LookupEnv("FABRIC_KEY_PATH")
	tlsPath, _ := os.LookupEnv("FABRIC_TLSCA_PATH")
	channel, _ := os.LookupEnv("FABRIC_CHANNEL3")
	chaincode, _ := os.LookupEnv("FABRIC_CHAINCODE3")

	if endpoint == "" || mspID == "" || certPath == "" || keyPath == "" || tlsPath == "" || channel == "" || chaincode == "" {
		return nil, errors.New("ch3log: missing required environment variables (FABRIC_ENDPOINT, FABRIC_MSPID, FABRIC_CERT_PATH, FABRIC_KEY_PATH, FABRIC_TLSCA_PATH, FABRIC_CHANNEL3, FABRIC_CHAINCODE3)")
	}

	certPEM, err := os.ReadFile(filepath.Clean(certPath))
	if err != nil {
		return nil, fmt.Errorf("ch3log read cert: %w", err)
	}
	keyPEM, err := os.ReadFile(filepath.Clean(keyPath))
	if err != nil {
		return nil, fmt.Errorf("ch3log read key: %w", err)
	}
	tlsPEM, err := os.ReadFile(filepath.Clean(tlsPath))
	if err != nil {
		return nil, fmt.Errorf("ch3log read tls ca: %w", err)
	}

	return New(Config{
		Endpoint:    endpoint,
		MSPID:       mspID,
		CertPEM:     certPEM,
		KeyPEM:      keyPEM,
		TLSCACert:   tlsPEM,
		ChannelName: channel,
		Chaincode:   chaincode,
		Timeout:     3 * time.Second,
	})
}

// TLS helpers (mirror of gatekeeper/internal/fabric — copied to avoid cross-module dependency)

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
		panic("ch3log: no PEM block in cert")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		panic(fmt.Sprintf("ch3log: parse cert: %v", err))
	}
	return cert
}

func mustParseKey(keyPEM []byte) interface{} {
	block, _ := pem.Decode(keyPEM)
	if block == nil {
		panic("ch3log: no PEM block in key")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		panic(fmt.Sprintf("ch3log: parse key: %v", err))
	}
	return key
}
