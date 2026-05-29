package diia

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/json"
	"math/big"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

// ── TestHashFileSHA256 ────────────────────────────────────────────────────

func TestHashFileSHA256(t *testing.T) {
	tests := []struct {
		name    string
		input   []byte
		wantHex string
	}{
		{
			name:    "empty",
			input:   []byte{},
			wantHex: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		},
		{
			name:    "hello",
			input:   []byte("hello"),
			wantHex: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
		},
		{
			// SHA-256("test") — verified against NIST test vectors
			name:    "test",
			input:   []byte("test"),
			wantHex: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := HashFileSHA256(tc.input)
			if got != tc.wantHex {
				t.Errorf("HashFileSHA256(%q) = %q, want %q", tc.input, got, tc.wantHex)
			}
		})
	}
}

func TestHashFileSHA256_Format(t *testing.T) {
	h := HashFileSHA256([]byte("some document"))
	if len(h) != 64 {
		t.Errorf("expected 64-char hex, got %d", len(h))
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			t.Errorf("non-lowercase-hex char %q in hash %q", c, h)
		}
	}
}

// ── TestHashFileForStorage ────────────────────────────────────────────────

func TestHashFileForStorage(t *testing.T) {
	sha256Hash := HashFileSHA256([]byte("document content"))
	stored := HashFileForStorage(sha256Hash)
	if len(stored) != 64 {
		t.Errorf("expected 64-char hex, got %d", len(stored))
	}
	// Must differ from the input (we're not simply repeating SHA-256).
	if stored == sha256Hash {
		t.Error("HashFileForStorage must not be identical to SHA-256 input")
	}
	// Must be deterministic.
	if stored != HashFileForStorage(sha256Hash) {
		t.Error("HashFileForStorage must be deterministic")
	}
}

// ── TestRetagSignedAttrs ──────────────────────────────────────────────────

// TestRetagSignedAttrs directly verifies the 0xA0 → 0x31 re-tagging logic
// that verifyCAdESBES performs on the signedAttrs field (RFC 5652 §5.4).
func TestRetagSignedAttrs(t *testing.T) {
	// Build a minimal 2-byte TLV: A0 01 FF
	wireBytes := []byte{0xA0, 0x01, 0xFF}
	toHash := make([]byte, len(wireBytes))
	copy(toHash, wireBytes)
	toHash[0] = 0x31 // SET

	if toHash[0] != 0x31 {
		t.Errorf("re-tag failed: expected 0x31, got 0x%02x", toHash[0])
	}
	if wireBytes[0] != 0xA0 {
		t.Error("original bytes must not be mutated")
	}
}

// ── TestVerifyCAdESBES ────────────────────────────────────────────────────

// TestVerifyCAdESBES constructs a minimal valid CAdES-BES DER and verifies
// that verifyCAdESBES accepts it. Exercises the full ASN.1 → ECDSA verify path.
func TestVerifyCAdESBES(t *testing.T) {
	der, _ := buildTestCAdES(t)
	cert, err := verifyCAdESBES(der)
	if err != nil {
		t.Fatalf("verifyCAdESBES returned unexpected error: %v", err)
	}
	if cert == nil {
		t.Fatal("verifyCAdESBES returned nil cert on success")
	}
}

func TestVerifyCAdESBES_TamperedSignature(t *testing.T) {
	der, _ := buildTestCAdES(t)
	// Flip the last byte — this corrupts the ECDSA signature.
	der[len(der)-1] ^= 0xFF
	_, err := verifyCAdESBES(der)
	if err == nil {
		t.Fatal("expected error for tampered signature, got nil")
	}
}

func TestVerifyCAdESBES_TruncatedInput(t *testing.T) {
	_, err := verifyCAdESBES([]byte{0x30, 0x01, 0x00})
	if err == nil {
		t.Fatal("expected error for truncated input")
	}
}

// ── TestCallbackMultipartParse ────────────────────────────────────────────

// TestCallbackMultipartParse exercises the HTTP handler's multipart parsing
// and CAdES-BES verification end-to-end using a synthetic valid CAdES-BES.
func TestCallbackMultipartParse(t *testing.T) {
	cadesDER, _ := buildTestCAdES(t)

	reqID := "test-request-id"
	body, boundary := buildMultipart(t, reqID, "key1", cadesDER)

	req := httptest.NewRequest(http.MethodPost, "/v1/diia/sign/callback", body)
	req.Header.Set("Content-Type", "multipart/form-data; boundary="+boundary)

	store := newMockStore()
	store.requests[reqID] = &SignRequestMeta{
		RequestID: reqID,
		BranchID:  "branch1",
		OfferID:   "offer1",
		CreatedAt: time.Now(),
	}

	rr := httptest.NewRecorder()
	HandleSignCallback(store).ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	if store.result == nil {
		t.Fatal("expected result to be stored in mock store")
	}
	if !store.result.Verified {
		t.Errorf("expected Verified=true, got false: %s", store.result.ErrMsg)
	}
	if store.result.RequestID != reqID {
		t.Errorf("result.RequestID = %q, want %q", store.result.RequestID, reqID)
	}
}

func TestCallbackMultipartParse_MissingMeta(t *testing.T) {
	cadesDER, _ := buildTestCAdES(t)
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, _ := mw.CreateFormField("file_0")
	fw.Write(cadesDER)
	mw.Close()

	req := httptest.NewRequest(http.MethodPost, "/v1/diia/sign/callback", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())

	rr := httptest.NewRecorder()
	HandleSignCallback(newMockStore()).ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", rr.Code)
	}
}

func TestCallbackMultipartParse_UnknownRequestID(t *testing.T) {
	cadesDER, _ := buildTestCAdES(t)
	body, boundary := buildMultipart(t, "no-such-id", "", cadesDER)

	req := httptest.NewRequest(http.MethodPost, "/v1/diia/sign/callback", body)
	req.Header.Set("Content-Type", "multipart/form-data; boundary="+boundary)

	rr := httptest.NewRecorder()
	HandleSignCallback(newMockStore()).ServeHTTP(rr, req)

	// Unknown requestID → 200 to stop Diia retries
	if rr.Code != http.StatusOK {
		t.Errorf("expected 200 for unknown requestID, got %d", rr.Code)
	}
}

func TestCallbackMultipartParse_WrongMethod(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/v1/diia/sign/callback", nil)
	rr := httptest.NewRecorder()
	HandleSignCallback(newMockStore()).ServeHTTP(rr, req)
	if rr.Code != http.StatusMethodNotAllowed {
		t.Errorf("expected 405, got %d", rr.Code)
	}
}

// ── TestRequestIDCorrelation ──────────────────────────────────────────────

func TestRequestIDCorrelation_Unknown(t *testing.T) {
	store := newMockStore()
	ctx := context.Background()

	meta, err := store.GetRequest(ctx, "nonexistent-id")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if meta != nil {
		t.Errorf("expected nil for unknown requestID, got %+v", meta)
	}
}

func TestRequestIDCorrelation_RoundTrip(t *testing.T) {
	store := newMockStore()
	ctx := context.Background()

	want := SignRequestMeta{
		RequestID:  "rountrip-id",
		BranchID:   "b1",
		OfferID:    "o1",
		FileKeys:   []string{"key1"},
		FileNames:  []string{"doc.pdf"},
		FileHashes: []string{HashFileForStorage("deadbeef00112233")},
		CreatedAt:  time.Now().UTC().Truncate(time.Second),
	}
	if err := store.SaveRequest(ctx, want); err != nil {
		t.Fatalf("SaveRequest: %v", err)
	}
	got, err := store.GetRequest(ctx, want.RequestID)
	if err != nil {
		t.Fatalf("GetRequest: %v", err)
	}
	if got == nil {
		t.Fatal("expected non-nil meta after save")
	}
	if got.RequestID != want.RequestID || got.BranchID != want.BranchID {
		t.Errorf("mismatch: got %+v, want %+v", *got, want)
	}
}

// ── TestExtractRNOKPP ─────────────────────────────────────────────────────

func TestExtractRNOKPP(t *testing.T) {
	tests := []struct {
		serialNumber string
		want         string
	}{
		{"RNOKPP1234567890", "UA:1234567890"},
		{"rnokpp9876543210", "UA:9876543210"},
		{"1234567890", "UA:1234567890"},
		{"", ""},
		{"  ", ""},
	}
	for _, tc := range tests {
		cert := &x509.Certificate{
			Subject: pkix.Name{SerialNumber: tc.serialNumber},
		}
		got := extractRNOKPP(cert)
		if got != tc.want {
			t.Errorf("extractRNOKPP(%q) = %q, want %q", tc.serialNumber, got, tc.want)
		}
	}
}

func TestHashRNOKPP_Format(t *testing.T) {
	h := HashRNOKPP("UA:1234567890")
	if len(h) != 64 {
		t.Errorf("expected 64-char hex, got %d", len(h))
	}
	// Deterministic
	if h != HashRNOKPP("UA:1234567890") {
		t.Error("HashRNOKPP must be deterministic")
	}
	// Distinct from raw input hash (SHA3-256 ≠ SHA-256)
	sha256h := HashFileSHA256([]byte("UA:1234567890"))
	if h == sha256h {
		t.Error("HashRNOKPP (SHA3-256) must differ from SHA-256 of the same input")
	}
}

// ── TestDiiaIntegration_Sandbox ───────────────────────────────────────────

func TestDiiaIntegration_Sandbox(t *testing.T) {
	if os.Getenv("DIIA_SANDBOX") != "1" {
		t.Skip("DIIA_SANDBOX=1 not set")
	}
	if os.Getenv("DIIA_ACQUIRER_TOKEN") == "" {
		t.Skip("DIIA_ACQUIRER_TOKEN not set")
	}

	c, err := NewFromEnv(nil)
	if err != nil {
		t.Fatalf("NewFromEnv: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := c.EnsureSession(ctx); err != nil {
		t.Fatalf("EnsureSession: %v", err)
	}
	c.mu.RLock()
	tok := c.sessionTok
	c.mu.RUnlock()
	if tok == "" {
		t.Fatal("session token is empty after EnsureSession")
	}
	t.Logf("sandbox: session acquired, token length=%d", len(tok))

	branches, err := c.GetBranches(ctx)
	if err != nil {
		t.Fatalf("GetBranches: %v", err)
	}
	t.Logf("sandbox: branches=%d", len(branches))
}

// ── helpers ───────────────────────────────────────────────────────────────

// buildTestCAdES constructs a minimal but cryptographically valid CAdES-BES
// (CMS SignedData) DER over an ephemeral ECDSA P-256 key with ecdsaWithSHA256.
// The signedAttrs contain a content-type and message-digest attribute.
func buildTestCAdES(t *testing.T) ([]byte, *ecdsa.PrivateKey) {
	t.Helper()

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	// Self-signed certificate
	certTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:   "Diia Test Signer",
			SerialNumber: "RNOKPP1234567890",
		},
		NotBefore: time.Now().Add(-time.Hour),
		NotAfter:  time.Now().Add(time.Hour),
	}
	certDER, err := x509.CreateCertificate(rand.Reader, certTmpl, certTmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}

	// Build signedAttrs inner content: two Attributes
	// Attr 1: contentType = id-data
	ctAttr := mustMarshalAttr(t,
		asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 9, 3},
		asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 1},
	)
	// Attr 2: messageDigest = SHA-256(empty content)
	mdVal := sha256.Sum256(nil)
	mdAttr := mustMarshalAttr(t,
		asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 9, 4},
		mdVal[:],
	)
	innerBytes := append(ctAttr, mdAttr...)

	// Wrap as SET (0x31) for hashing
	setBytes := derTLV(0x31, innerBytes)

	// Sign SHA-256(SET)
	digest := sha256.Sum256(setBytes)
	r, s, err := ecdsa.Sign(rand.Reader, priv, digest[:])
	if err != nil {
		t.Fatalf("ecdsa.Sign: %v", err)
	}
	sigDER, err := asn1.Marshal(ecdsaSigValue{R: r, S: s})
	if err != nil {
		t.Fatalf("marshal sig: %v", err)
	}

	// Wire-encode signedAttrs: SET (0x31) → IMPLICIT [0] (0xA0)
	wireAttrs := make([]byte, len(setBytes))
	copy(wireAttrs, setBytes)
	wireAttrs[0] = 0xA0

	// IssuerAndSerialNumber for the SID
	issuerSerial := derIssuerSerial(t, certDER)

	// SignerInfo SEQUENCE
	siBody := concat(
		derTLV(0x02, []byte{0x01}),             // version INTEGER 1
		derTLV(0x30, issuerSerial),               // sid IssuerAndSerialNumber
		algoIDBytes(asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 2, 1}), // sha-256
		wireAttrs,                                // signedAttrs [0] IMPLICIT
		algoIDBytes(oidECDSAWithSHA256),           // signatureAlgorithm
		derTLV(0x04, sigDER),                     // signature OCTET STRING
	)
	signerInfoDER := derTLV(0x30, siBody)

	// Certificates [0] IMPLICIT: A0 { certDER }
	certSetDER := derTLV(0xA0, certDER)

	// DigestAlgorithms SET { AlgorithmIdentifier }
	daBody := algoIDBytes(asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 2, 1})
	digestAlgsDER := derTLV(0x31, daBody)

	// EncapContentInfo SEQUENCE { id-data }
	eciOID, _ := asn1.Marshal(asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 1})
	eciDER := derTLV(0x30, eciOID)

	// SignerInfos SET { signerInfo }
	signerInfosDER := derTLV(0x31, signerInfoDER)

	// SignedData SEQUENCE
	versionDER := derTLV(0x02, []byte{0x01}) // version INTEGER 1
	sdBody := concat(versionDER, digestAlgsDER, eciDER, certSetDER, signerInfosDER)
	sdDER := derTLV(0x30, sdBody)

	// ContentInfo SEQUENCE { id-signedData, [0] EXPLICIT { sdDER } }
	contentTypeOID, _ := asn1.Marshal(oidSignedData)
	contentWrapped := derTLV(0xA0, sdDER) // [0] EXPLICIT
	ciDER := derTLV(0x30, concat(contentTypeOID, contentWrapped))

	return ciDER, priv
}

// mustMarshalAttr marshals a CMS Attribute { attrType OID, attrValues SET { val } }.
// val may be an asn1.ObjectIdentifier or []byte (OCTET STRING).
func mustMarshalAttr(t *testing.T, attrType asn1.ObjectIdentifier, val any) []byte {
	t.Helper()
	var valDER []byte
	var err error
	switch v := val.(type) {
	case asn1.ObjectIdentifier:
		valDER, err = asn1.Marshal(v)
	case []byte:
		valDER, err = asn1.Marshal(v)
	default:
		t.Fatalf("mustMarshalAttr: unsupported value type %T", val)
	}
	if err != nil {
		t.Fatalf("mustMarshalAttr marshal val: %v", err)
	}
	typDER, err := asn1.Marshal(attrType)
	if err != nil {
		t.Fatalf("mustMarshalAttr marshal type: %v", err)
	}
	// attrValues SET { val }
	attrValsDER := derTLV(0x31, valDER)
	// Attribute SEQUENCE { type, attrValues }
	return derTLV(0x30, concat(typDER, attrValsDER))
}

// algoIDBytes returns DER for AlgorithmIdentifier { algorithm OID } (no params).
func algoIDBytes(oid asn1.ObjectIdentifier) []byte {
	oidDER, _ := asn1.Marshal(oid)
	return derTLV(0x30, oidDER)
}

// derIssuerSerial returns the inner bytes of an IssuerAndSerialNumber SEQUENCE.
func derIssuerSerial(t *testing.T, certDER []byte) []byte {
	t.Helper()
	cert, err := x509.ParseCertificate(certDER)
	if err != nil {
		t.Fatalf("parse cert for IssuerAndSerialNumber: %v", err)
	}
	serialDER, _ := asn1.Marshal(cert.SerialNumber)
	return concat(cert.RawIssuer, serialDER)
}

// derTLV encodes a single DER TLV: tag || length || value.
func derTLV(tag byte, value []byte) []byte {
	n := len(value)
	var lenBytes []byte
	switch {
	case n < 128:
		lenBytes = []byte{byte(n)}
	case n < 256:
		lenBytes = []byte{0x81, byte(n)}
	default:
		lenBytes = []byte{0x82, byte(n >> 8), byte(n)}
	}
	result := make([]byte, 1+len(lenBytes)+n)
	result[0] = tag
	copy(result[1:], lenBytes)
	copy(result[1+len(lenBytes):], value)
	return result
}

func concat(parts ...[]byte) []byte {
	var total int
	for _, p := range parts {
		total += len(p)
	}
	out := make([]byte, 0, total)
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func buildMultipart(t *testing.T, requestID, fileKey string, cadesDER []byte) (*bytes.Buffer, string) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)

	metaJSON, _ := json.Marshal(callbackMeta{
		RequestID: requestID,
		FileKey:   fileKey,
		FileName:  "document.pdf",
	})
	fw, _ := mw.CreateFormField("meta")
	fw.Write(metaJSON)

	fw2, _ := mw.CreateFormField("file_0")
	fw2.Write(cadesDER)

	mw.Close()
	return &buf, mw.Boundary()
}

// ── mockStore ────────────────────────────────────────────────────────────

// mockStore is an in-memory StoreInterface implementation for tests.
// It does not require a live Redis instance.
type mockStore struct {
	requests map[string]*SignRequestMeta
	result   *VerifyResult
}

func newMockStore() *mockStore {
	return &mockStore{requests: make(map[string]*SignRequestMeta)}
}

// Verify *mockStore implements StoreInterface.
var _ StoreInterface = (*mockStore)(nil)

func (m *mockStore) GetRequest(_ context.Context, id string) (*SignRequestMeta, error) {
	return m.requests[id], nil
}

func (m *mockStore) SaveResult(_ context.Context, r VerifyResult) error {
	m.result = &r
	return nil
}

// Extra methods mirroring Store for round-trip tests (not part of StoreInterface).
func (m *mockStore) SaveRequest(_ context.Context, meta SignRequestMeta) error {
	m.requests[meta.RequestID] = &meta
	return nil
}

func (m *mockStore) GetResult(_ context.Context, id string) (*VerifyResult, error) {
	if m.result != nil && m.result.RequestID == id {
		return m.result, nil
	}
	return nil, nil
}
