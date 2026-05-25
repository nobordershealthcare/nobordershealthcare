// Package odoo syncs referral conversions and commission records to Odoo CRM
// via the Odoo JSON-RPC API (XML-RPC v2 / JSON endpoint).
// Only hashes and financial data are transmitted — no PII.
package odoo

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/nobordershealthcare/referral/internal/models"
)

// Client is a minimal Odoo JSON-RPC client.
type Client struct {
	baseURL  string
	db       string
	uid      int
	password string
	hc       *http.Client
}

type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	ID      int    `json:"id"`
	Params  any    `json:"params"`
}

type rpcResponse struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// New creates an Odoo client from environment variables:
//
//	ODOO_URL, ODOO_DB, ODOO_UID (int), ODOO_PASSWORD
func New() *Client {
	uid := 0
	fmt.Sscan(os.Getenv("ODOO_UID"), &uid) //nolint:errcheck
	return &Client{
		baseURL:  os.Getenv("ODOO_URL"),
		db:       os.Getenv("ODOO_DB"),
		uid:      uid,
		password: os.Getenv("ODOO_PASSWORD"),
		hc:       &http.Client{Timeout: 10 * time.Second},
	}
}

// SyncConversion creates or updates an nbhc.referral.conversion record in Odoo.
// Only SHA3-256 hashes and non-PII financial fields are transmitted.
func (c *Client) SyncConversion(ctx context.Context, conv *models.ReferralConversion) error {
	vals := map[string]any{
		"conversion_id":   conv.ID,
		"referrer_hash":   conv.ReferrerHash,
		"referred_hash":   conv.ReferredHash,
		"referral_type":   string(conv.ReferralType),
		"plan_tier":       conv.PlanTier,
		"commission_rate": conv.CommissionRate,
		"commission_type": conv.CommissionType,
		"status":          conv.Status,
		"converted_at":    conv.ConvertedAt.Format(time.RFC3339),
	}
	return c.callModel(ctx, "nbhc.referral.conversion", "create_or_update_by_ref", []any{vals})
}

// SyncAccrual creates or updates an nbhc.commission.accrual record in Odoo.
func (c *Client) SyncAccrual(ctx context.Context, a *models.CommissionAccrual) error {
	vals := map[string]any{
		"accrual_id":       a.ID,
		"conversion_id":    a.ConversionID,
		"period":           a.Period,
		"revenue_amount":   a.RevenueAmount,
		"commission_amount": a.CommissionAmount,
		"referrer_hash":    a.ReferrerHash,
		"status":           a.Status,
		"stripe_tx_id":     a.StripeTxID,
	}
	return c.callModel(ctx, "nbhc.commission.accrual", "create_or_update_by_ref", []any{vals})
}

func (c *Client) callModel(ctx context.Context, model, method string, args []any) error {
	params := map[string]any{
		"service": "object",
		"method":  "execute_kw",
		"args":    []any{c.db, c.uid, c.password, model, method, args},
	}
	req := rpcRequest{JSONRPC: "2.0", Method: "call", ID: 1, Params: params}

	body, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("odoo marshal: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.baseURL+"/web/dataset/call_kw", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("odoo request build: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.hc.Do(httpReq)
	if err != nil {
		return fmt.Errorf("odoo http: %w", err)
	}
	defer resp.Body.Close()

	var rpcResp rpcResponse
	if err := json.NewDecoder(resp.Body).Decode(&rpcResp); err != nil {
		return fmt.Errorf("odoo decode: %w", err)
	}
	if rpcResp.Error != nil {
		return fmt.Errorf("odoo rpc error: %s", rpcResp.Error.Message)
	}
	return nil
}
