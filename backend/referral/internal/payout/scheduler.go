package payout

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/nobordershealthcare/referral/internal/models"
	"github.com/nobordershealthcare/referral/internal/odoo"
	"github.com/nobordershealthcare/referral/internal/store"
)

// Scheduler triggers monthly commission payouts on the 1st of each month.
type Scheduler struct {
	db     *store.DB
	stripe *Client
	odooC  *odoo.Client
}

// NewScheduler creates a Scheduler wired to the supplied dependencies.
func NewScheduler(db *store.DB, stripe *Client, odooC *odoo.Client) *Scheduler {
	return &Scheduler{db: db, stripe: stripe, odooC: odooC}
}

// Start launches a background goroutine that fires RunMonthlyPayout on the
// 1st of every calendar month at 02:00 UTC.
func (s *Scheduler) Start(ctx context.Context) {
	go func() {
		for {
			next := nextFirstOfMonth()
			log.Printf("[scheduler] next payout run at %s", next.Format(time.RFC3339))
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Until(next)):
				period := prevMonthPeriod(next)
				log.Printf("[scheduler] running monthly payout for period %s", period)
				if err := s.RunMonthlyPayout(ctx, period); err != nil {
					log.Printf("[scheduler] payout error period=%s: %v", period, err)
				}
			}
		}
	}()
}

// RunMonthlyPayout aggregates all pending accruals for the given period,
// groups them by Stripe Connect account, applies minimum thresholds, transfers,
// marks paid, and syncs each accrual to Odoo.
func (s *Scheduler) RunMonthlyPayout(ctx context.Context, period string) error {
	accruals, err := s.db.ListPendingAccrualsByPeriod(ctx, period)
	if err != nil {
		return fmt.Errorf("list accruals: %w", err)
	}

	// Group by StripeAccountID → sum total commission
	type group struct {
		accountID string
		total     float64
		ids       []string
		accruals  []models.CommissionAccrual
	}
	groups := map[string]*group{}
	for _, a := range accruals {
		if a.StripeAccountID == "" {
			continue // credit-based types (individual/provider) — no Stripe payout
		}
		g, ok := groups[a.StripeAccountID]
		if !ok {
			g = &group{accountID: a.StripeAccountID}
			groups[a.StripeAccountID] = g
		}
		g.total += a.CommissionAmount
		g.ids = append(g.ids, a.ID)
		g.accruals = append(g.accruals, a)
	}

	for _, g := range groups {
		// Determine minimum threshold based on total accumulated (use €50 default).
		// Individual accruals below threshold accumulate until they cross it.
		minEUR := 50.0 // partner minimum; affiliate minimum is €100 (checked per type)
		for _, a := range g.accruals {
			conv, convErr := s.db.GetConversion(ctx, a.ConversionID)
			if convErr == nil && conv.ReferralType == models.TypeAffiliate {
				minEUR = 100.0
				break
			}
		}
		if g.total < minEUR {
			log.Printf("[scheduler] accountID=%.8s below minimum (%.2f < %.2f EUR) — accumulating",
				g.accountID, g.total, minEUR)
			continue
		}

		txID, transferErr := s.stripe.Transfer(g.accountID, g.total, period)
		if transferErr != nil {
			log.Printf("[scheduler] transfer failed accountID=%.8s: %v", g.accountID, transferErr)
			for _, id := range g.ids {
				_ = s.db.MarkAccrualFailed(ctx, id)
			}
			continue
		}

		paidAt := time.Now().UTC()
		for i, id := range g.ids {
			if markErr := s.db.MarkAccrualPaid(ctx, id, txID, paidAt); markErr != nil {
				log.Printf("[scheduler] MarkAccrualPaid id=%s: %v", id, markErr)
			}
			a := g.accruals[i]
			a.Status = models.StatusPaid
			a.StripeTxID = txID
			paid := paidAt
			a.PaidAt = &paid
			if syncErr := s.odooC.SyncAccrual(ctx, &a); syncErr != nil {
				log.Printf("[scheduler] OdooSync accrual id=%s: %v", id, syncErr)
			}
		}
		log.Printf("[scheduler] paid accountID=%.8s EUR=%.2f txID=%s", g.accountID, g.total, txID)
	}
	return nil
}

// nextFirstOfMonth returns the next 02:00 UTC on the 1st of the next month.
func nextFirstOfMonth() time.Time {
	now := time.Now().UTC()
	first := time.Date(now.Year(), now.Month()+1, 1, 2, 0, 0, 0, time.UTC)
	if now.Day() == 1 && now.Hour() < 2 {
		// still early on the 1st — fire today
		first = time.Date(now.Year(), now.Month(), 1, 2, 0, 0, 0, time.UTC)
	}
	return first
}

// prevMonthPeriod returns the YYYY-MM string for the month before the given time.
func prevMonthPeriod(t time.Time) string {
	prev := t.AddDate(0, -1, 0)
	return fmt.Sprintf("%04d-%02d", prev.Year(), int(prev.Month()))
}
