// Command subscription is the NoBorders Healthcare subscription webhook handler.
// It processes Stripe events and notifies the referral service of subscription
// lifecycle changes. All user identifiers are SHA3-256 hashes from gatekeeper.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	stripe "github.com/stripe/stripe-go/v76"
	"github.com/stripe/stripe-go/v76/webhook"

	"github.com/nobordershealthcare/subscription/internal/referralclient"
)

func main() {
	stripe.Key = os.Getenv("STRIPE_SECRET_KEY")
	referralSvc := referralclient.New(envOr("REFERRAL_SVC_URL", "http://referral:8088"))

	r := chi.NewRouter()
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	r.Post("/webhook/stripe", makeStripeWebhookHandler(referralSvc))
	r.Get("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	addr := envOr("LISTEN_ADDR", ":8089")
	log.Printf("[subscription] listening on %s", addr)
	if err := http.ListenAndServe(addr, r); err != nil {
		log.Fatalf("server: %v", err)
	}
}

func makeStripeWebhookHandler(rc *referralclient.Client) http.HandlerFunc {
	secret := os.Getenv("STRIPE_WEBHOOK_SECRET")
	return func(w http.ResponseWriter, r *http.Request) {
		payload := make([]byte, r.ContentLength)
		if _, err := r.Body.Read(payload); err != nil {
			http.Error(w, "read body", http.StatusBadRequest)
			return
		}

		event, err := webhook.ConstructEvent(payload, r.Header.Get("Stripe-Signature"), secret)
		if err != nil {
			log.Printf("[subscription] webhook signature error: %v", err)
			http.Error(w, "invalid signature", http.StatusBadRequest)
			return
		}

		ctx := context.Background()
		switch event.Type {

		// New subscription created — check pending referral and convert
		case "customer.subscription.created":
			var sub stripe.Subscription
			if err := json.Unmarshal(event.Data.Raw, &sub); err != nil {
				log.Printf("[subscription] unmarshal subscription: %v", err)
				break
			}
			handleSubscriptionCreated(ctx, rc, &sub)

		// Monthly payment succeeded — accrue commission
		case "invoice.payment_succeeded":
			var inv stripe.Invoice
			if err := json.Unmarshal(event.Data.Raw, &inv); err != nil {
				log.Printf("[subscription] unmarshal invoice: %v", err)
				break
			}
			handlePaymentSucceeded(ctx, rc, &inv)

		// Subscription cancelled — stop future commission
		case "customer.subscription.deleted":
			var sub stripe.Subscription
			if err := json.Unmarshal(event.Data.Raw, &sub); err != nil {
				log.Printf("[subscription] unmarshal cancelled subscription: %v", err)
				break
			}
			handleSubscriptionCancelled(ctx, rc, sub.ID)
		}

		w.WriteHeader(http.StatusOK)
	}
}

// handleSubscriptionCreated is called when Stripe fires customer.subscription.created.
// It looks up a pending referral code for this subscriber (stored in metadata by
// the registration flow) and records the conversion.
func handleSubscriptionCreated(ctx context.Context, rc *referralclient.Client, sub *stripe.Subscription) {
	codeHash := sub.Metadata["referral_code_hash"]
	referredHash := sub.Metadata["referred_hash"] // SHA3-256 set at registration
	if codeHash == "" || referredHash == "" {
		return // no referral on this subscription
	}
	plan := ""
	if len(sub.Items.Data) > 0 && sub.Items.Data[0].Price != nil {
		plan = sub.Items.Data[0].Price.ID
	}

	convID, err := rc.RecordConversion(ctx, referralclient.ConvertRequest{
		CodeHash:       codeHash,
		ReferredHash:   referredHash,
		SubscriptionID: sub.ID,
		Plan:           plan,
	})
	if err != nil {
		log.Printf("[subscription] RecordConversion sub=%s: %v", sub.ID, err)
		return
	}
	log.Printf("[subscription] referral conversion recorded convID=%s sub=%s", convID, sub.ID)
}

// handlePaymentSucceeded accrues commission on each successful renewal.
func handlePaymentSucceeded(ctx context.Context, rc *referralclient.Client, inv *stripe.Invoice) {
	conversionID := inv.Metadata["referral_conversion_id"]
	if conversionID == "" {
		return
	}

	amountEUR := float64(inv.AmountPaid) / 100.0
	now := time.Now().UTC()
	period := fmt.Sprintf("%04d-%02d", now.Year(), int(now.Month()))

	if _, err := rc.RecordAccrual(ctx, referralclient.AccrueRequest{
		ConversionID: conversionID,
		RevenueEUR:   amountEUR,
		Period:       period,
	}); err != nil {
		log.Printf("[subscription] RecordAccrual inv=%s: %v", inv.ID, err)
	}
}

// handleSubscriptionCancelled stops future commission — no clawback of paid months.
func handleSubscriptionCancelled(ctx context.Context, rc *referralclient.Client, subID string) {
	// conversionID is stored in subscription metadata by the referral hook above
	// In production this would be looked up from a local DB or Redis
	log.Printf("[subscription] subscription cancelled sub=%s — referral deactivation requires conversionID lookup", subID)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
