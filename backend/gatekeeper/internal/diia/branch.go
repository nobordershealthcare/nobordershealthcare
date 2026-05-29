package diia

import (
	"context"
	"fmt"
	"net/http"
)

// Scopes defines which Diia services an acquirer branch or offer can access.
// DiiaID contains the list of requested service identifiers, e.g.:
//   - "hashedFilesSigning" — document signing via Diia.Підпис
//   - "auth"              — identity verification via Diia.ID
type Scopes struct {
	DiiaID []string `json:"diiaId"`
}

// ScopeSigning returns a Scopes value requesting document signing permission.
func ScopeSigning() Scopes { return Scopes{DiiaID: []string{"hashedFilesSigning"}} }

// ScopeAuth returns a Scopes value requesting identity auth permission.
func ScopeAuth() Scopes { return Scopes{DiiaID: []string{"auth"}} }

// Branch represents a Diia acquirer branch — the legal/physical entity
// that citizens interact with through the Diia app.
type Branch struct {
	ID               string   `json:"id,omitempty"`
	Name             string   `json:"name"`
	Email            string   `json:"email"`
	Region           string   `json:"region"`
	District         string   `json:"district"`
	Location         string   `json:"location"`
	Street           string   `json:"street"`
	House            string   `json:"house"`
	DeliveryTypes    []string `json:"deliveryTypes"`
	Scopes           Scopes   `json:"scopes"`
	ReturnLink       string   `json:"returnLink,omitempty"`
	CallbackEndpoint string   `json:"callbackEndpoint,omitempty"`
}

// CreateBranchRequest is the payload for POST /api/v1/acquirers/branch.
// CallbackEndpoint must be an HTTPS URL accessible by Diia servers.
type CreateBranchRequest struct {
	Name             string   `json:"name"`
	Email            string   `json:"email"`
	Region           string   `json:"region"`
	District         string   `json:"district"`
	Location         string   `json:"location"`
	Street           string   `json:"street"`
	House            string   `json:"house"`
	DeliveryTypes    []string `json:"deliveryTypes"`
	Scopes           Scopes   `json:"scopes"`
	ReturnLink       string   `json:"returnLink,omitempty"`
	CallbackEndpoint string   `json:"callbackEndpoint,omitempty"`
}

// UpdateBranchRequest is the payload for PUT /api/v1/acquirers/branch/{branchId}.
// Only non-zero fields are sent. ID is set by the caller via the URL path.
type UpdateBranchRequest struct {
	Name             string   `json:"name,omitempty"`
	Email            string   `json:"email,omitempty"`
	Region           string   `json:"region,omitempty"`
	District         string   `json:"district,omitempty"`
	Location         string   `json:"location,omitempty"`
	Street           string   `json:"street,omitempty"`
	House            string   `json:"house,omitempty"`
	DeliveryTypes    []string `json:"deliveryTypes,omitempty"`
	Scopes           *Scopes  `json:"scopes,omitempty"`
	ReturnLink       string   `json:"returnLink,omitempty"`
	CallbackEndpoint string   `json:"callbackEndpoint,omitempty"`
}

type branchesResponse struct {
	Branches []Branch `json:"branches"`
}

// CreateBranch calls POST /api/v1/acquirers/branch and returns the created branch.
func (c *Client) CreateBranch(ctx context.Context, req CreateBranchRequest) (*Branch, error) {
	var b Branch
	if err := c.doJSON(ctx, http.MethodPost, "/api/v1/acquirers/branch", req, &b); err != nil {
		return nil, fmt.Errorf("diia: CreateBranch: %w", err)
	}
	return &b, nil
}

// GetBranches calls GET /api/v1/acquirers/branch and returns all branches for
// this acquirer.
func (c *Client) GetBranches(ctx context.Context) ([]Branch, error) {
	var resp branchesResponse
	if err := c.doJSON(ctx, http.MethodGet, "/api/v1/acquirers/branch", nil, &resp); err != nil {
		return nil, fmt.Errorf("diia: GetBranches: %w", err)
	}
	return resp.Branches, nil
}

// GetBranch calls GET /api/v1/acquirers/branch/{branchId} and returns the
// identified branch.
func (c *Client) GetBranch(ctx context.Context, branchID string) (*Branch, error) {
	if branchID == "" {
		return nil, fmt.Errorf("diia: GetBranch: branchID is required")
	}
	var b Branch
	path := fmt.Sprintf("/api/v1/acquirers/branch/%s", branchID)
	if err := c.doJSON(ctx, http.MethodGet, path, nil, &b); err != nil {
		return nil, fmt.Errorf("diia: GetBranch %s: %w", branchID, err)
	}
	return &b, nil
}

// UpdateBranch calls PUT /api/v1/acquirers/branch/{branchId} and returns the
// updated branch.
func (c *Client) UpdateBranch(ctx context.Context, branchID string, req UpdateBranchRequest) (*Branch, error) {
	if branchID == "" {
		return nil, fmt.Errorf("diia: UpdateBranch: branchID is required")
	}
	var b Branch
	path := fmt.Sprintf("/api/v1/acquirers/branch/%s", branchID)
	if err := c.doJSON(ctx, http.MethodPut, path, req, &b); err != nil {
		return nil, fmt.Errorf("diia: UpdateBranch %s: %w", branchID, err)
	}
	return &b, nil
}

// DeleteBranch calls DELETE /api/v1/acquirers/branch/{branchId}.
// Returns nil on success (204 No Content).
func (c *Client) DeleteBranch(ctx context.Context, branchID string) error {
	if branchID == "" {
		return fmt.Errorf("diia: DeleteBranch: branchID is required")
	}
	path := fmt.Sprintf("/api/v1/acquirers/branch/%s", branchID)
	if err := c.doJSON(ctx, http.MethodDelete, path, nil, nil); err != nil {
		return fmt.Errorf("diia: DeleteBranch %s: %w", branchID, err)
	}
	return nil
}
