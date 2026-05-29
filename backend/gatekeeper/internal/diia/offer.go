package diia

import (
	"context"
	"fmt"
	"net/http"
)

// Offer represents a Diia acquirer offer — defines the set of documents or
// services that citizens can provide/sign in a session.
type Offer struct {
	ID         string `json:"id,omitempty"`
	Name       string `json:"name"`
	Scopes     Scopes `json:"scopes"`
	ReturnLink string `json:"returnLink,omitempty"`
}

// CreateOfferRequest is the payload for
// POST /api/v1/acquirers/branch/{branchId}/offer.
type CreateOfferRequest struct {
	Name       string `json:"name"`
	Scopes     Scopes `json:"scopes"`
	ReturnLink string `json:"returnLink,omitempty"`
}

type offersResponse struct {
	Offers []Offer `json:"offers"`
}

// CreateOffer calls POST /api/v1/acquirers/branch/{branchId}/offer and returns
// the created offer.
func (c *Client) CreateOffer(ctx context.Context, branchID string, req CreateOfferRequest) (*Offer, error) {
	if branchID == "" {
		return nil, fmt.Errorf("diia: CreateOffer: branchID is required")
	}
	path := fmt.Sprintf("/api/v1/acquirers/branch/%s/offer", branchID)
	var o Offer
	if err := c.doJSON(ctx, http.MethodPost, path, req, &o); err != nil {
		return nil, fmt.Errorf("diia: CreateOffer branch=%s: %w", branchID, err)
	}
	return &o, nil
}

// ListOffers calls GET /api/v1/acquirers/branch/{branchId}/offer and returns
// all offers under the identified branch.
func (c *Client) ListOffers(ctx context.Context, branchID string) ([]Offer, error) {
	if branchID == "" {
		return nil, fmt.Errorf("diia: ListOffers: branchID is required")
	}
	path := fmt.Sprintf("/api/v1/acquirers/branch/%s/offer", branchID)
	var resp offersResponse
	if err := c.doJSON(ctx, http.MethodGet, path, nil, &resp); err != nil {
		return nil, fmt.Errorf("diia: ListOffers branch=%s: %w", branchID, err)
	}
	return resp.Offers, nil
}

// DeleteOffer calls DELETE /api/v1/acquirers/branch/{branchId}/offer/{offerId}.
// Returns nil on success (204 No Content).
func (c *Client) DeleteOffer(ctx context.Context, branchID, offerID string) error {
	if branchID == "" {
		return fmt.Errorf("diia: DeleteOffer: branchID is required")
	}
	if offerID == "" {
		return fmt.Errorf("diia: DeleteOffer: offerID is required")
	}
	path := fmt.Sprintf("/api/v1/acquirers/branch/%s/offer/%s", branchID, offerID)
	if err := c.doJSON(ctx, http.MethodDelete, path, nil, nil); err != nil {
		return fmt.Errorf("diia: DeleteOffer branch=%s offer=%s: %w", branchID, offerID, err)
	}
	return nil
}
