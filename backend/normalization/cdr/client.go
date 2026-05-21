package cdr

import (
	"crypto/tls"
	"fmt"
	"os"

	"github.com/gocql/gocql"
)

// NewSession creates a ScyllaDB CQL session with TLS 1.3 and credential auth.
// All connection parameters come from env vars — no hardcoded secrets.
//
// Required env vars:
//
//	SCYLLA_HOSTS   comma-separated host list
//	SCYLLA_USER    CQL username (from k8s secret)
//	SCYLLA_PASS    CQL password (from k8s secret)
//	SCYLLA_CERT    path to client certificate file
//	SCYLLA_KEY     path to client private key file
//	SCYLLA_CA      path to CA certificate file
func NewSession(hosts []string, certFile, keyFile, caFile string) (*gocql.Session, error) {
	cluster := gocql.NewCluster(hosts...)
	cluster.Keyspace = "cdr"
	cluster.Consistency = gocql.Quorum // reads + writes quorum for strong consistency
	cluster.NumConns = 2               // connections per host

	tlsCfg, err := buildCDRTLS(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("cdr TLS: %w", err)
	}
	cluster.SslOpts = &gocql.SslOptions{
		Config:                 tlsCfg,
		EnableHostVerification: true,
		CaPath:                 caFile,
	}
	cluster.Authenticator = gocql.PasswordAuthenticator{
		Username: os.Getenv("SCYLLA_USER"),
		Password: os.Getenv("SCYLLA_PASS"), // injected by k8s Secret volume
	}

	session, err := cluster.CreateSession()
	if err != nil {
		return nil, fmt.Errorf("create ScyllaDB session: %w", err)
	}
	return session, nil
}

func buildCDRTLS(certFile, keyFile string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("load client keypair: %w", err)
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS13, // TLS 1.3 minimum — never TLS 1.2
		Certificates: []tls.Certificate{cert},
	}, nil
}
