// Package referralclient is the HTTP client used by the subscription service
// to notify the referral service of new subscriptions and monthly payments.
// All user identifiers sent here are SHA3-256 hashes — no PII is transmitted.
package referralclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// Client calls the referral service REST API.
type Client struct {
	baseURL string
	hc      *http.Client
}

// New creates a Client pointed at the referral service.
func New(baseURL string) *Client {
	return &Client{
		baseURL: baseURL,
		hc:      &http.Client{Timeout: 10 * time.Second},
	}
}

// ConvertRequest is the payload for POST /referral/convert.
type ConvertRequest struct {
	CodeHash       string `json:"code_hash"`
	ReferredHash   string `json:"referred_hash"` // SHA3-256 — no PII
	SubscriptionID string `json:"subscription_id"`
	Plan           string `json:"plan"`
}

// AccrueRequest is the payload for POST /referral/accrue.
type AccrueRequest struct {
	ConversionID string  `json:"conversion_id"`
	RevenueEUR   float64 `json:"revenue_eur"`
	Period       string  `json:"period"` // "YYYY-MM"
}

// RecordConversion notifies the referral service of a new subscription.
// Returns the conversion_id, or "" if no referral code was on file.
func (c *Client) RecordConversion(ctx context.Context, req ConvertRequest) (string, error) {
	return c.postJSON(ctx, "/referral/convert", req)
}

// RecordAccrual notifies the referral service of a monthly payment event.
func (c *Client) RecordAccrual(ctx context.Context, req AccrueRequest) (string, error) {
	return c.postJSON(ctx, "/referral/accrue", req)
}

// DeactivateConversion tells the referral service a subscription was cancelled.
func (c *Client) DeactivateConversion(ctx context.Context, conversionID string) error {
	url := fmt.Sprintf("%s/referral/deactivate/%s", c.baseURL, conversionID)
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	resp, err := c.hc.Do(httpReq)
	if err != nil {
		return fmt.Errorf("deactivate: %w", err)
	}
	resp.Body.Close()
	return nil
}

func (c *Client) postJSON(ctx context.Context, path string, payload any) (string, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("http: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("referral service returned %d", resp.StatusCode)
	}

	var result map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", nil // non-fatal, some endpoints return 204
	}
	for _, k := range []string{"conversion_id", "accrual_id"} {
		if v, ok := result[k]; ok {
			return v, nil
		}
	}
	return "", nil
}
