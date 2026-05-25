// Package payout handles Stripe Connect partner onboarding and commission transfers.
package payout

import (
	"fmt"
	"math"
	"os"

	stripe "github.com/stripe/stripe-go/v76"
	"github.com/stripe/stripe-go/v76/account"
	"github.com/stripe/stripe-go/v76/accountlink"
	"github.com/stripe/stripe-go/v76/transfer"
)

// Client wraps Stripe Connect operations.
type Client struct{}

// New initialises the Stripe SDK from the STRIPE_SECRET_KEY env var.
func New() *Client {
	stripe.Key = os.Getenv("STRIPE_SECRET_KEY")
	return &Client{}
}

// OnboardPartner creates a Stripe Express Connect account and returns the
// account ID and the hosted onboarding URL the partner should be redirected to.
// No PII is passed — the partner fills in personal details on Stripe's side.
func (c *Client) OnboardPartner(refreshURL, returnURL string) (accountID, onboardURL string, err error) {
	acct, err := account.New(&stripe.AccountParams{
		Type: stripe.String("express"),
		Capabilities: &stripe.AccountCapabilitiesParams{
			Transfers: &stripe.AccountCapabilitiesTransfersParams{
				Requested: stripe.Bool(true),
			},
		},
	})
	if err != nil {
		return "", "", fmt.Errorf("stripe account create: %w", err)
	}

	link, err := accountlink.New(&stripe.AccountLinkParams{
		Account:    stripe.String(acct.ID),
		RefreshURL: stripe.String(refreshURL),
		ReturnURL:  stripe.String(returnURL),
		Type:       stripe.String("account_onboarding"),
	})
	if err != nil {
		return "", "", fmt.Errorf("stripe account link: %w", err)
	}

	return acct.ID, link.URL, nil
}

// Transfer sends commissionEUR to the partner's Stripe Connect account.
// Returns the Stripe transfer ID.
func (c *Client) Transfer(stripeAccountID string, commissionEUR float64, period string) (txID string, err error) {
	amountCents := int64(math.Round(commissionEUR * 100))
	if amountCents <= 0 {
		return "", fmt.Errorf("transfer amount must be positive, got %d cents", amountCents)
	}

	t, err := transfer.New(&stripe.TransferParams{
		Amount:      stripe.Int64(amountCents),
		Currency:    stripe.String("eur"),
		Destination: stripe.String(stripeAccountID),
		Description: stripe.String("Referral commission " + period),
	})
	if err != nil {
		return "", fmt.Errorf("stripe transfer: %w", err)
	}

	return t.ID, nil
}
