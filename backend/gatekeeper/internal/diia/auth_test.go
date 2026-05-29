package diia

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// ── TestMaskRNOKPP ────────────────────────────────────────────────────────

func TestMaskRNOKPP(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"1234567890", "••••••7890"}, // standard 10-digit Ukrainian tax ID
		{"12345678",   "••••5678"},
		{"1234",       "1234"},       // exactly 4 — all visible
		{"123",        "•••"},        // fewer than 4 — all hidden
		{"",           ""},
	}
	for _, tc := range tests {
		got := maskRNOKPP(tc.input)
		if got != tc.want {
			t.Errorf("maskRNOKPP(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

func TestMaskRNOKPP_LastFourVisible(t *testing.T) {
	rnokpp := "9876543210"
	masked := maskRNOKPP(rnokpp)
	if !strings.HasSuffix(masked, "3210") {
		t.Errorf("maskRNOKPP(%q) = %q: last 4 digits must be visible", rnokpp, masked)
	}
}

// ── TestExtractIdentity ───────────────────────────────────────────────────

func TestExtractIdentity_TopLevel(t *testing.T) {
	cb := &diiaAuthCallback{
		RequestID:      "req1",
		TaxpayerNumber: "1234567890",
		FirstName:      "Іван",
		Patronymic:     "Петрович",
		LastName:       "Петренко",
	}
	rnokpp, first, pat, last := cb.extractIdentity()
	if rnokpp != "1234567890" || first != "Іван" || pat != "Петрович" || last != "Петренко" {
		t.Errorf("extractIdentity top-level: got (%q,%q,%q,%q)", rnokpp, first, pat, last)
	}
}

func TestExtractIdentity_DocumentsPreferred(t *testing.T) {
	cb := &diiaAuthCallback{
		RequestID:      "req1",
		TaxpayerNumber: "WRONG",
		FirstName:      "Wrong",
		Documents: []authDocument{{
			Type:           "internal-passport",
			TaxpayerNumber: "9876543210",
			FirstName:      "Марія",
			Patronymic:     "Іванівна",
			LastName:       "Коваль",
		}},
	}
	rnokpp, first, _, last := cb.extractIdentity()
	if rnokpp != "9876543210" || first != "Марія" || last != "Коваль" {
		t.Errorf("extractIdentity documents: got (%q,%q,%q)", rnokpp, first, last)
	}
}

// ── TestHandleAuthRequest ─────────────────────────────────────────────────

func TestHandleAuthRequest_Success(t *testing.T) {
	t.Setenv("DIIA_BRANCH_ID", "branch1")
	t.Setenv("DIIA_OFFER_ID_AUTH", "offerA")

	store := newMockAuthStore()
	client := &mockAuthClient{
		requestID: "auth-req-uuid",
		deeplink:  "https://diia.app/acquirers/auth-req-uuid",
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/diia/auth/request", nil)
	rr := httptest.NewRecorder()
	HandleAuthRequest(client, store).ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	var resp map[string]string
	json.NewDecoder(rr.Body).Decode(&resp)
	if resp["requestId"] == "" {
		t.Error("requestId missing from response")
	}
	if resp["deeplink"] != "https://diia.app/acquirers/auth-req-uuid" {
		t.Errorf("unexpected deeplink: %q", resp["deeplink"])
	}
	if store.savedRequest == nil {
		t.Error("auth request not saved to store")
	}
}

func TestHandleAuthRequest_ClientError(t *testing.T) {
	t.Setenv("DIIA_BRANCH_ID", "branch1")
	t.Setenv("DIIA_OFFER_ID_AUTH", "offerA")

	req := httptest.NewRequest(http.MethodPost, "/v1/diia/auth/request", nil)
	rr := httptest.NewRecorder()
	HandleAuthRequest(&mockAuthClient{err: errDiiaDown}, newMockAuthStore()).ServeHTTP(rr, req)

	if rr.Code != http.StatusServiceUnavailable {
		t.Errorf("expected 503, got %d", rr.Code)
	}
}

func TestHandleAuthRequest_WrongMethod(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/v1/diia/auth/request", nil)
	rr := httptest.NewRecorder()
	HandleAuthRequest(&mockAuthClient{}, newMockAuthStore()).ServeHTTP(rr, req)
	if rr.Code != http.StatusMethodNotAllowed {
		t.Errorf("expected 405, got %d", rr.Code)
	}
}

// ── TestHandleAuthStatus ──────────────────────────────────────────────────

func TestHandleAuthStatus_Pending(t *testing.T) {
	store := newMockAuthStore()
	store.requests["known-id"] = &AuthRequestMeta{RequestID: "known-id"}

	req := httptest.NewRequest(http.MethodGet, "/v1/diia/auth/status/known-id", nil)
	req.SetPathValue("requestId", "known-id")
	rr := httptest.NewRecorder()
	HandleAuthStatus(store).ServeHTTP(rr, req)

	var resp map[string]string
	json.NewDecoder(rr.Body).Decode(&resp)
	if resp["status"] != "pending" {
		t.Errorf("expected pending, got %q", resp["status"])
	}
}

func TestHandleAuthStatus_Expired(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/v1/diia/auth/status/no-such-id", nil)
	req.SetPathValue("requestId", "no-such-id")
	rr := httptest.NewRecorder()
	HandleAuthStatus(newMockAuthStore()).ServeHTTP(rr, req)

	var resp map[string]string
	json.NewDecoder(rr.Body).Decode(&resp)
	if resp["status"] != "expired" {
		t.Errorf("expected expired, got %q", resp["status"])
	}
}

func TestHandleAuthStatus_Complete(t *testing.T) {
	store := newMockAuthStore()
	store.requests["done-id"] = &AuthRequestMeta{RequestID: "done-id"}
	store.results["done-id"] = &AuthResult{
		RequestID:  "done-id",
		Status:     "complete",
		FirstName:  "Іван",
		Patronymic: "Петрович",
		LastName:   "Петренко",
		RNOKPPMask: "••••••7890",
		RNOKPPHash: HashRNOKPP("UA:1234567890"),
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/diia/auth/status/done-id", nil)
	req.SetPathValue("requestId", "done-id")
	rr := httptest.NewRecorder()
	HandleAuthStatus(store).ServeHTTP(rr, req)

	var resp map[string]any
	json.NewDecoder(rr.Body).Decode(&resp)
	if resp["status"] != "complete" {
		t.Errorf("expected complete, got %v", resp["status"])
	}
	payload, ok := resp["payload"].(map[string]any)
	if !ok {
		t.Fatal("payload missing or wrong type")
	}
	if payload["rnokppMasked"] != "••••••7890" {
		t.Errorf("expected masked rnokpp, got %v", payload["rnokppMasked"])
	}
	if payload["rnokppHash"] == "" {
		t.Error("rnokppHash must be present in complete payload")
	}
	// Full RNOKPP must NOT be in response body
	if strings.Contains(rr.Body.String(), "1234567890") {
		t.Error("plaintext RNOKPP must not appear in response")
	}
	// C-02: one-time use — both Redis keys must be deleted after serving "complete".
	if _, exists := store.requests["done-id"]; exists {
		t.Error("C-02: auth request key must be deleted after complete response (requestId replay prevention)")
	}
	if _, exists := store.results["done-id"]; exists {
		t.Error("C-02: auth result key must be deleted after complete response (requestId replay prevention)")
	}
}

func TestHandleAuthStatus_Failed(t *testing.T) {
	store := newMockAuthStore()
	store.requests["fail-id"] = &AuthRequestMeta{RequestID: "fail-id"}
	store.results["fail-id"] = &AuthResult{
		RequestID:  "fail-id",
		Status:     "failed",
		FailReason: "user cancelled",
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/diia/auth/status/fail-id", nil)
	req.SetPathValue("requestId", "fail-id")
	rr := httptest.NewRecorder()
	HandleAuthStatus(store).ServeHTTP(rr, req)

	var resp map[string]string
	json.NewDecoder(rr.Body).Decode(&resp)
	if resp["status"] != "failed" || resp["reason"] != "user cancelled" {
		t.Errorf("unexpected response: %v", resp)
	}
	// C-02: one-time use — both Redis keys must be deleted after serving "failed".
	if _, exists := store.requests["fail-id"]; exists {
		t.Error("C-02: auth request key must be deleted after failed response")
	}
	if _, exists := store.results["fail-id"]; exists {
		t.Error("C-02: auth result key must be deleted after failed response")
	}
}

// ── TestHandleAuthCallback ────────────────────────────────────────────────

func TestHandleAuthCallback_Success(t *testing.T) {
	store := newMockAuthStore()
	store.requests["cb-req"] = &AuthRequestMeta{RequestID: "cb-req"}

	body, _ := json.Marshal(diiaAuthCallback{
		RequestID:      "cb-req",
		TaxpayerNumber: "1234567890",
		FirstName:      "Іван",
		Patronymic:     "Петрович",
		LastName:       "Петренко",
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/diia/auth/callback", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	HandleAuthCallback(store).ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rr.Code, rr.Body.String())
	}
	result := store.results["cb-req"]
	if result == nil {
		t.Fatal("result not stored")
	}
	if result.Status != "complete" {
		t.Errorf("expected complete, got %q", result.Status)
	}
	// RNOKPP hash must be SHA3-256("UA:1234567890")
	wantHash := HashRNOKPP("UA:1234567890")
	if result.RNOKPPHash != wantHash {
		t.Errorf("hash mismatch: got %q, want %q", result.RNOKPPHash, wantHash)
	}
	if result.RNOKPPMask != "••••••7890" {
		t.Errorf("unexpected mask: %q", result.RNOKPPMask)
	}
	if result.FirstName != "Іван" || result.LastName != "Петренко" {
		t.Error("identity fields not stored correctly")
	}
}

func TestHandleAuthCallback_DocumentsFormat(t *testing.T) {
	store := newMockAuthStore()
	store.requests["doc-req"] = &AuthRequestMeta{RequestID: "doc-req"}

	body, _ := json.Marshal(diiaAuthCallback{
		RequestID: "doc-req",
		Documents: []authDocument{{
			Type:           "internal-passport",
			TaxpayerNumber: "9876543210",
			FirstName:      "Марія",
			Patronymic:     "Іванівна",
			LastName:       "Коваль",
		}},
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/diia/auth/callback", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	HandleAuthCallback(store).ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	result := store.results["doc-req"]
	if result == nil {
		t.Fatal("result not stored")
	}
	if result.RNOKPPHash != HashRNOKPP("UA:9876543210") {
		t.Error("RNOKPP hash mismatch for document-format callback")
	}
	if result.LastName != "Коваль" {
		t.Errorf("unexpected LastName: %q", result.LastName)
	}
}

func TestHandleAuthCallback_UnknownRequestID(t *testing.T) {
	body, _ := json.Marshal(diiaAuthCallback{RequestID: "ghost-id"})
	req := httptest.NewRequest(http.MethodPost, "/v1/diia/auth/callback", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	HandleAuthCallback(newMockAuthStore()).ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected 200 to stop Diia retries, got %d", rr.Code)
	}
}

func TestHandleAuthCallback_MissingRequestID(t *testing.T) {
	body, _ := json.Marshal(map[string]string{"foo": "bar"})
	req := httptest.NewRequest(http.MethodPost, "/v1/diia/auth/callback", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	HandleAuthCallback(newMockAuthStore()).ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", rr.Code)
	}
}

// ── mockAuthStore ────────────────────────────────────────────────────────

type mockAuthStore struct {
	requests     map[string]*AuthRequestMeta
	results      map[string]*AuthResult
	savedRequest *AuthRequestMeta
}

func newMockAuthStore() *mockAuthStore {
	return &mockAuthStore{
		requests: make(map[string]*AuthRequestMeta),
		results:  make(map[string]*AuthResult),
	}
}

var _ AuthStoreInterface = (*mockAuthStore)(nil)

func (m *mockAuthStore) SaveAuthRequest(_ context.Context, meta AuthRequestMeta) error {
	m.requests[meta.RequestID] = &meta
	m.savedRequest = &meta
	return nil
}
func (m *mockAuthStore) GetAuthRequest(_ context.Context, id string) (*AuthRequestMeta, error) {
	return m.requests[id], nil
}
func (m *mockAuthStore) SaveAuthResult(_ context.Context, r AuthResult) error {
	m.results[r.RequestID] = &r
	return nil
}
func (m *mockAuthStore) GetAuthResult(_ context.Context, id string) (*AuthResult, error) {
	return m.results[id], nil
}
func (m *mockAuthStore) DeleteAuthRequest(_ context.Context, id string) error {
	delete(m.requests, id)
	return nil
}
func (m *mockAuthStore) DeleteAuthResult(_ context.Context, id string) error {
	delete(m.results, id)
	return nil
}

// ── mockAuthClient ────────────────────────────────────────────────────────

var errDiiaDown = errors.New("diia: service unavailable")

type mockAuthClient struct {
	requestID string
	deeplink  string
	err       error
}

var _ ClientInterface = (*mockAuthClient)(nil)

func (m *mockAuthClient) RequestAuth(_ context.Context, _, _ string) (string, string, error) {
	if m.err != nil {
		return "", "", m.err
	}
	id := m.requestID
	if id == "" {
		id = "mock-" + time.Now().Format("150405.000")
	}
	return id, m.deeplink, nil
}

// Stub the remaining ClientInterface methods (not exercised by auth handlers).
func (m *mockAuthClient) CreateBranch(_ context.Context, _ CreateBranchRequest) (*Branch, error) {
	return nil, errDiiaDown
}
func (m *mockAuthClient) GetBranches(_ context.Context) ([]Branch, error) {
	return nil, errDiiaDown
}
func (m *mockAuthClient) GetBranch(_ context.Context, _ string) (*Branch, error) {
	return nil, errDiiaDown
}
func (m *mockAuthClient) UpdateBranch(_ context.Context, _ string, _ UpdateBranchRequest) (*Branch, error) {
	return nil, errDiiaDown
}
func (m *mockAuthClient) DeleteBranch(_ context.Context, _ string) error { return errDiiaDown }
func (m *mockAuthClient) CreateOffer(_ context.Context, _ string, _ CreateOfferRequest) (*Offer, error) {
	return nil, errDiiaDown
}
func (m *mockAuthClient) ListOffers(_ context.Context, _ string) ([]Offer, error) {
	return nil, errDiiaDown
}
func (m *mockAuthClient) DeleteOffer(_ context.Context, _, _ string) error { return errDiiaDown }
func (m *mockAuthClient) RequestSign(_ context.Context, _, _ string, _ []HashedFile) (string, string, error) {
	return "", "", errDiiaDown
}
func (m *mockAuthClient) GetSigningDeeplink(_ context.Context, _, _, _ string, _ []HashedFile) (string, error) {
	return "", errDiiaDown
}
func (m *mockAuthClient) GetAuthDeeplink(_ context.Context, _, _, _ string) (string, error) {
	return "", errDiiaDown
}
func (m *mockAuthClient) GetStatus(_ context.Context, _, _ string) (string, error) {
	return "", errDiiaDown
}
