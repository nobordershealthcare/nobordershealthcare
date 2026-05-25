// Package store provides ScyllaDB persistence for the referral service.
// All keys are SHA3-256 hashes — no PII is written to the database.
package store

import (
	"context"
	"fmt"
	"time"

	"github.com/gocql/gocql"
	"github.com/nobordershealthcare/referral/internal/models"
)

// DB wraps a gocql.Session and exposes typed CRUD operations.
type DB struct {
	session *gocql.Session
}

// New connects to ScyllaDB and returns a ready DB.
func New(hosts []string, keyspace string) (*DB, error) {
	cluster := gocql.NewCluster(hosts...)
	cluster.Keyspace = keyspace
	cluster.Consistency = gocql.Quorum
	cluster.ProtoVersion = 4

	sess, err := cluster.CreateSession()
	if err != nil {
		return nil, fmt.Errorf("scylla connect: %w", err)
	}
	return &DB{session: sess}, nil
}

// Close releases the ScyllaDB session.
func (d *DB) Close() { d.session.Close() }

// ── Referral codes ──────────────────────────────────────────────────────────

func (d *DB) CreateCode(ctx context.Context, rc *models.ReferralCode) error {
	return d.session.Query(
		`INSERT INTO referral_codes
		 (code_hash, code, referrer_hash, referral_type, stripe_account_id,
		  created_at, expires_at, usage_count, usage_limit, active)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		rc.CodeHash, rc.Code, rc.ReferrerHash, string(rc.ReferralType),
		rc.StripeAccountID, rc.CreatedAt, rc.ExpiresAt,
		rc.UsageCount, rc.UsageLimit, rc.Active,
	).WithContext(ctx).Exec()
}

func (d *DB) GetCodeByCode(ctx context.Context, code string) (*models.ReferralCode, error) {
	var codeHash string
	if err := d.session.Query(
		`SELECT code_hash FROM referral_codes_by_code WHERE code = ?`, code,
	).WithContext(ctx).Scan(&codeHash); err != nil {
		return nil, fmt.Errorf("lookup code: %w", err)
	}
	return d.GetCodeByHash(ctx, codeHash)
}

func (d *DB) GetCodeByHash(ctx context.Context, codeHash string) (*models.ReferralCode, error) {
	var rc models.ReferralCode
	var rtype string
	err := d.session.Query(
		`SELECT code_hash, code, referrer_hash, referral_type, stripe_account_id,
		        created_at, expires_at, usage_count, usage_limit, active
		 FROM referral_codes WHERE code_hash = ?`,
		codeHash,
	).WithContext(ctx).Scan(
		&rc.CodeHash, &rc.Code, &rc.ReferrerHash, &rtype, &rc.StripeAccountID,
		&rc.CreatedAt, &rc.ExpiresAt, &rc.UsageCount, &rc.UsageLimit, &rc.Active,
	)
	if err != nil {
		return nil, fmt.Errorf("get code by hash: %w", err)
	}
	rc.ReferralType = models.ReferralType(rtype)
	return &rc, nil
}

func (d *DB) IncrementUsage(ctx context.Context, codeHash string) error {
	return d.session.Query(
		`UPDATE referral_codes SET usage_count = usage_count + 1 WHERE code_hash = ?`,
		codeHash,
	).WithContext(ctx).Exec()
}

func (d *DB) PauseCode(ctx context.Context, codeHash string) error {
	return d.session.Query(
		`UPDATE referral_codes SET active = false WHERE code_hash = ?`, codeHash,
	).WithContext(ctx).Exec()
}

// ── Conversions ─────────────────────────────────────────────────────────────

func (d *DB) CreateConversion(ctx context.Context, c *models.ReferralConversion) error {
	return d.session.Query(
		`INSERT INTO referral_conversions
		 (id, code_hash, referrer_hash, referred_hash, referral_type, stripe_account_id,
		  converted_at, subscription_id, plan_tier, commission_rate, commission_type, status)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		c.ID, c.CodeHash, c.ReferrerHash, c.ReferredHash, string(c.ReferralType),
		c.StripeAccountID, c.ConvertedAt, c.SubscriptionID, c.PlanTier,
		c.CommissionRate, c.CommissionType, c.Status,
	).WithContext(ctx).Exec()
}

func (d *DB) GetConversion(ctx context.Context, id string) (*models.ReferralConversion, error) {
	var c models.ReferralConversion
	var rtype string
	err := d.session.Query(
		`SELECT id, code_hash, referrer_hash, referred_hash, referral_type, stripe_account_id,
		        converted_at, subscription_id, plan_tier, commission_rate, commission_type, status
		 FROM referral_conversions WHERE id = ?`, id,
	).WithContext(ctx).Scan(
		&c.ID, &c.CodeHash, &c.ReferrerHash, &c.ReferredHash, &rtype, &c.StripeAccountID,
		&c.ConvertedAt, &c.SubscriptionID, &c.PlanTier, &c.CommissionRate, &c.CommissionType, &c.Status,
	)
	if err != nil {
		return nil, fmt.Errorf("get conversion: %w", err)
	}
	c.ReferralType = models.ReferralType(rtype)
	return &c, nil
}

func (d *DB) ListConversionsByReferrer(ctx context.Context, referrerHash string) ([]models.ReferralConversion, error) {
	iter := d.session.Query(
		`SELECT id, code_hash, referrer_hash, referred_hash, referral_type, stripe_account_id,
		        converted_at, subscription_id, plan_tier, commission_rate, commission_type, status
		 FROM referral_conversions_by_referrer WHERE referrer_hash = ?`, referrerHash,
	).WithContext(ctx).Iter()

	var out []models.ReferralConversion
	var c models.ReferralConversion
	var rtype string
	for iter.Scan(
		&c.ID, &c.CodeHash, &c.ReferrerHash, &c.ReferredHash, &rtype, &c.StripeAccountID,
		&c.ConvertedAt, &c.SubscriptionID, &c.PlanTier, &c.CommissionRate, &c.CommissionType, &c.Status,
	) {
		c.ReferralType = models.ReferralType(rtype)
		out = append(out, c)
	}
	return out, iter.Close()
}

func (d *DB) DeactivateConversion(ctx context.Context, id string) error {
	return d.session.Query(
		`UPDATE referral_conversions SET status = ? WHERE id = ?`,
		models.StatusCancelled, id,
	).WithContext(ctx).Exec()
}

func (d *DB) CountActiveByReferrer(ctx context.Context, referrerHash string) (int, error) {
	convs, err := d.ListConversionsByReferrer(ctx, referrerHash)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, c := range convs {
		if c.Status == models.StatusApproved {
			n++
		}
	}
	return n, nil
}

// ── Commission accruals ──────────────────────────────────────────────────────

func (d *DB) CreateAccrual(ctx context.Context, a *models.CommissionAccrual) error {
	return d.session.Query(
		`INSERT INTO commission_accruals
		 (id, conversion_id, period, revenue_amount, commission_amount,
		  referrer_hash, stripe_account_id, status)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		a.ID, a.ConversionID, a.Period, a.RevenueAmount, a.CommissionAmount,
		a.ReferrerHash, a.StripeAccountID, a.Status,
	).WithContext(ctx).Exec()
}

func (d *DB) ListPendingAccrualsByPeriod(ctx context.Context, period string) ([]models.CommissionAccrual, error) {
	iter := d.session.Query(
		`SELECT id, conversion_id, period, revenue_amount, commission_amount,
		        referrer_hash, stripe_account_id, status
		 FROM commission_accruals_by_period
		 WHERE period = ? AND status = ?`, period, models.StatusPending,
	).WithContext(ctx).Iter()

	var out []models.CommissionAccrual
	var a models.CommissionAccrual
	for iter.Scan(
		&a.ID, &a.ConversionID, &a.Period, &a.RevenueAmount, &a.CommissionAmount,
		&a.ReferrerHash, &a.StripeAccountID, &a.Status,
	) {
		out = append(out, a)
	}
	return out, iter.Close()
}

func (d *DB) MarkAccrualPaid(ctx context.Context, id, stripeTxID string, paidAt time.Time) error {
	return d.session.Query(
		`UPDATE commission_accruals SET status = ?, stripe_tx_id = ?, paid_at = ? WHERE id = ?`,
		models.StatusPaid, stripeTxID, paidAt, id,
	).WithContext(ctx).Exec()
}

func (d *DB) MarkAccrualFailed(ctx context.Context, id string) error {
	return d.session.Query(
		`UPDATE commission_accruals SET status = ? WHERE id = ?`,
		models.StatusFailed, id,
	).WithContext(ctx).Exec()
}

func (d *DB) SumPendingCommission(ctx context.Context, referrerHash string) (float64, error) {
	accruals, err := d.listAccrualsByReferrer(ctx, referrerHash, models.StatusPending)
	if err != nil {
		return 0, err
	}
	var sum float64
	for _, a := range accruals {
		sum += a.CommissionAmount
	}
	return sum, nil
}

func (d *DB) SumPaidCommission(ctx context.Context, referrerHash string) (float64, error) {
	accruals, err := d.listAccrualsByReferrer(ctx, referrerHash, models.StatusPaid)
	if err != nil {
		return 0, err
	}
	var sum float64
	for _, a := range accruals {
		sum += a.CommissionAmount
	}
	return sum, nil
}

func (d *DB) listAccrualsByReferrer(ctx context.Context, referrerHash, status string) ([]models.CommissionAccrual, error) {
	iter := d.session.Query(
		`SELECT id, conversion_id, period, revenue_amount, commission_amount,
		        referrer_hash, stripe_account_id, status
		 FROM commission_accruals WHERE referrer_hash = ? AND status = ? ALLOW FILTERING`,
		referrerHash, status,
	).WithContext(ctx).Iter()

	var out []models.CommissionAccrual
	var a models.CommissionAccrual
	for iter.Scan(
		&a.ID, &a.ConversionID, &a.Period, &a.RevenueAmount, &a.CommissionAmount,
		&a.ReferrerHash, &a.StripeAccountID, &a.Status,
	) {
		out = append(out, a)
	}
	return out, iter.Close()
}

// ── Attribution chain ────────────────────────────────────────────────────────

func (d *DB) AppendAttributionCode(ctx context.Context, referredHash, codeHash string) error {
	return d.session.Query(
		`UPDATE attribution_chain SET codes = codes + ? WHERE referred_hash = ?`,
		[]string{codeHash}, referredHash,
	).WithContext(ctx).Exec()
}

func (d *DB) GetAttributionChain(ctx context.Context, referredHash string) ([]string, error) {
	var codes []string
	err := d.session.Query(
		`SELECT codes FROM attribution_chain WHERE referred_hash = ?`, referredHash,
	).WithContext(ctx).Scan(&codes)
	if err == gocql.ErrNotFound {
		return nil, nil
	}
	return codes, err
}
