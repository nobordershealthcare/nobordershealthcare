// odoo_sync.go — Odoo 17 XML-RPC synchronisation.
//
// Syncs partner approval events and monthly API-call totals to Odoo.
// Uses the two standard Odoo XML-RPC endpoints:
//
//	/xmlrpc/2/common  → authenticate
//	/xmlrpc/2/object  → execute_kw (create / write / search_read)
//
// Environment variables (all required when Odoo sync is enabled):
//
//	ODOO_URL   base URL, e.g. https://erp.noborders.health
//	ODOO_DB    database name
//	ODOO_USER  service account login
//	ODOO_KEY   service account password / API key
//
// Security: the Odoo service account credential (ODOO_KEY) is read once at startup
// and never written to logs. Partner data written to Odoo includes only the
// key hash (not the raw key) and non-PII operational fields.
package partner

import (
	"errors"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/kolo/xmlrpc"
)

// OdooClient is a thin Odoo XML-RPC client scoped to one authenticated session.
type OdooClient struct {
	baseURL string
	db      string
	user    string
	cred    string // service account credential — never logged
	uid     int
}

// NewOdooClient builds and authenticates an OdooClient from environment variables.
// Returns an error if any required variable is missing or authentication fails.
func NewOdooClient() (*OdooClient, error) {
	c := &OdooClient{
		baseURL: os.Getenv("ODOO_URL"),
		db:      os.Getenv("ODOO_DB"),
		user:    os.Getenv("ODOO_USER"),
		cred:    os.Getenv("ODOO_KEY"),
	}
	if c.baseURL == "" || c.db == "" || c.user == "" || c.cred == "" {
		return nil, errors.New("odoo sync: ODOO_URL, ODOO_DB, ODOO_USER, ODOO_KEY must all be set")
	}
	if err := c.authenticate(); err != nil {
		return nil, fmt.Errorf("odoo sync: authenticate: %w", err)
	}
	return c, nil
}

// authenticate calls /xmlrpc/2/common.authenticate and stores the uid.
func (c *OdooClient) authenticate() error {
	cl, err := xmlrpc.NewClient(c.baseURL+"/xmlrpc/2/common", nil)
	if err != nil {
		return fmt.Errorf("common client: %w", err)
	}

	var uid int
	err = cl.Call("authenticate", []interface{}{
		c.db,
		c.user,
		c.cred,
		map[string]interface{}{},
	}, &uid)
	if err != nil {
		return fmt.Errorf("xmlrpc call authenticate: %w", err)
	}
	if uid == 0 {
		return errors.New("authentication rejected — check ODOO_USER and ODOO_KEY")
	}
	c.uid = uid
	return nil
}

// executeKw calls /xmlrpc/2/object.execute_kw and stores the result in reply.
func (c *OdooClient) executeKw(model, method string, args []interface{}, kwargs map[string]interface{}, reply interface{}) error {
	cl, err := xmlrpc.NewClient(c.baseURL+"/xmlrpc/2/object", nil)
	if err != nil {
		return fmt.Errorf("object client: %w", err)
	}
	params := []interface{}{
		c.db,
		c.uid,
		c.cred,
		model,
		method,
		args,
	}
	if kwargs != nil {
		params = append(params, kwargs)
	}
	return cl.Call("execute_kw", params, reply)
}

// SyncPartnerApproval creates or updates the nbhc.api.partner record in Odoo
// when a partner is approved. The key hash (SHA3-256 hex) is written; the raw key
// is NEVER included in any Odoo call.
func (c *OdooClient) SyncPartnerApproval(p *Partner) error {
	// Search for an existing record by partner_id (our internal UUID stored in Odoo).
	var existingIDs []int
	searchArgs := []interface{}{
		[]interface{}{
			[]interface{}{"x_nbhc_partner_id", "=", p.ID},
		},
	}
	if err := c.executeKw("nbhc.api.partner", "search", searchArgs, nil, &existingIDs); err != nil {
		// Non-fatal: model may not exist yet during initial deployment.
		log.Printf("odoo sync: search nbhc.api.partner for %s: %v", p.ID, err)
	}

	vals := map[string]interface{}{
		"name":             p.Name,
		"partner_type":     string(p.Type),
		"api_key_hash":     p.KeyHash,
		"fhir_version":     p.FHIRVersion,
		"rate_limit_tier":  string(p.Tier),
		"status":           string(p.Status),
		"x_nbhc_partner_id": p.ID,
	}

	if len(existingIDs) > 0 {
		// Update existing record.
		writeArgs := []interface{}{existingIDs, vals}
		var ok bool
		if err := c.executeKw("nbhc.api.partner", "write", writeArgs, nil, &ok); err != nil {
			return fmt.Errorf("write nbhc.api.partner id=%d: %w", existingIDs[0], err)
		}
	} else {
		// Create new record.
		var newID int
		createArgs := []interface{}{vals}
		if err := c.executeKw("nbhc.api.partner", "create", createArgs, nil, &newID); err != nil {
			return fmt.Errorf("create nbhc.api.partner: %w", err)
		}
		log.Printf("odoo sync: created nbhc.api.partner id=%d for partner %s", newID, p.ID)
	}

	// If an Odoo res.partner ID is linked, update it with approval status.
	if p.OdooID > 0 {
		rpVals := map[string]interface{}{
			"comment": fmt.Sprintf("NoBorders API partner approved — type=%s tier=%s", p.Type, p.Tier),
		}
		writeRP := []interface{}{[]int{p.OdooID}, rpVals}
		var ok bool
		if err := c.executeKw("res.partner", "write", writeRP, nil, &ok); err != nil {
			log.Printf("odoo sync: update res.partner id=%d: %v", p.OdooID, err)
		}
	}
	return nil
}

// SyncMonthlyCalls updates the monthly_calls field on nbhc.api.partner.
// partnerID is our internal UUID; calls is the total for the given month.
// Called at month-end by the billing service.
func (c *OdooClient) SyncMonthlyCalls(partnerID string, calls int, month time.Time) error {
	var ids []int
	searchArgs := []interface{}{
		[]interface{}{
			[]interface{}{"x_nbhc_partner_id", "=", partnerID},
		},
	}
	if err := c.executeKw("nbhc.api.partner", "search", searchArgs, nil, &ids); err != nil {
		return fmt.Errorf("search nbhc.api.partner: %w", err)
	}
	if len(ids) == 0 {
		return fmt.Errorf("nbhc.api.partner not found for partner %s", partnerID)
	}
	vals := map[string]interface{}{
		"monthly_calls": calls,
		"last_sync_month": month.Format("2006-01"),
	}
	writeArgs := []interface{}{ids, vals}
	var ok bool
	if err := c.executeKw("nbhc.api.partner", "write", writeArgs, nil, &ok); err != nil {
		return fmt.Errorf("write monthly_calls: %w", err)
	}
	log.Printf("odoo sync: monthly calls updated: partner=%s month=%s calls=%d",
		partnerID, month.Format("2006-01"), calls)
	return nil
}
