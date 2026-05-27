# models/commission_accrual.py — nbhc.commission.accrual
#
# One row per (conversion, billing-period). Aggregated monthly for Stripe payout.

from odoo import models, fields, api


class CommissionAccrual(models.Model):
    _name = 'nbhc.commission.accrual'
    _description = 'NoBorders Healthcare Commission Accrual'
    _inherit = ['mail.thread']
    _rec_name = 'display_name_computed'
    _order = 'period desc, id desc'

    # ── Identity ─────────────────────────────────────────────────────────────
    accrual_id = fields.Char(
        string='Accrual ID (UUID)', required=True, readonly=True, index=True,
    )
    conversion_id = fields.Many2one(
        'nbhc.referral.conversion',
        string='Conversion',
        ondelete='restrict',
        index=True,
    )
    period = fields.Char(
        string='Period (YYYY-MM)',
        required=True,
        help='Billing month, e.g. "2026-05".',
    )

    # ── Amounts ───────────────────────────────────────────────────────────────
    revenue_amount = fields.Float(string='Revenue (EUR)', digits=(10, 2))
    commission_amount = fields.Float(
        string='Commission (EUR)', digits=(10, 2), tracking=True,
    )
    referrer_hash = fields.Char(
        string='Referrer Hash (SHA3-256)', readonly=True,
    )

    # ── Stripe ────────────────────────────────────────────────────────────────
    status = fields.Selection(
        selection=[
            ('pending', 'Pending'),
            ('paid',    'Paid'),
            ('failed',  'Failed'),
        ],
        string='Status',
        default='pending',
        tracking=True,
    )
    paid_at = fields.Datetime(string='Paid At', readonly=True)
    stripe_tx_id = fields.Char(string='Stripe Transfer ID', readonly=True)

    # ── Computed display ──────────────────────────────────────────────────────
    display_name_computed = fields.Char(
        string='Display', compute='_compute_display', store=False,
    )

    @api.depends('period', 'commission_amount')
    def _compute_display(self):
        for rec in self:
            rec.display_name_computed = f"{rec.period} — €{rec.commission_amount:.2f}"

    # ── XML-RPC hook: called by the Go referral service ───────────────────────
    def create_or_update_by_ref(self, vals_list):
        """Upsert accrual records received from the Go referral service."""
        for vals in vals_list:
            accrual_ref = vals.get('accrual_id')
            existing = self.search([('accrual_id', '=', accrual_ref)], limit=1)
            if existing:
                existing.write({k: v for k, v in vals.items() if k != 'accrual_id'})
            else:
                self.create(vals)
        return True

    # ── Monthly report action ─────────────────────────────────────────────────
    @api.model
    def action_generate_monthly_report(self, period=None):
        """Generate a commission summary report for the given period.
        Called by the automated action on the 1st of each month.
        """
        if not period:
            from datetime import date
            prev = date.today().replace(day=1)
            import calendar
            prev = prev.replace(
                month=prev.month - 1 if prev.month > 1 else 12,
                year=prev.year if prev.month > 1 else prev.year - 1,
            )
            period = prev.strftime('%Y-%m')

        accruals = self.search([('period', '=', period), ('status', '=', 'pending')])
        total = sum(a.commission_amount for a in accruals)

        # Post summary to chatter of each accrual
        for accrual in accruals:
            accrual.message_post(
                body=f"Commission report for {period}: €{accrual.commission_amount:.2f} pending. "
                     f"Period total: €{total:.2f}",
                subject=f"Commission Report {period}",
            )
        return {'period': period, 'total': total, 'count': len(accruals)}
