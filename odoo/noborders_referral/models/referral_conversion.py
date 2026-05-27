# models/referral_conversion.py — nbhc.referral.conversion
#
# Each record represents one successful referral activation.
# referred_hash is SHA3-256(salt+referredID) — no PII stored.

from odoo import models, fields


class ReferralConversion(models.Model):
    _name = 'nbhc.referral.conversion'
    _description = 'NoBorders Healthcare Referral Conversion'
    _inherit = ['mail.thread']
    _rec_name = 'conversion_id'
    _order = 'converted_at desc'

    # ── Identity ─────────────────────────────────────────────────────────────
    conversion_id = fields.Char(
        string='Conversion ID (UUID)',
        required=True,
        readonly=True,
        index=True,
    )
    code_id = fields.Many2one(
        'nbhc.referral.code',
        string='Referral Code',
        ondelete='restrict',
        index=True,
    )

    # ── Hashes (no PII) ───────────────────────────────────────────────────────
    referrer_hash = fields.Char(
        string='Referrer Hash (SHA3-256)',
        readonly=True,
        help='SHA3-256(salt+referrerID) — never contains a name, ID number, or address.',
    )
    referred_hash = fields.Char(
        string='Referred Hash (SHA3-256)',
        readonly=True,
        help='SHA3-256(salt+referredID) — no PII stored in Odoo.',
    )

    # ── Subscription ──────────────────────────────────────────────────────────
    referral_type = fields.Selection(
        related='code_id.referral_type', string='Type', store=True,
    )
    plan_tier = fields.Char(string='Plan Tier')
    converted_at = fields.Datetime(string='Converted At', readonly=True)

    # ── Commission ────────────────────────────────────────────────────────────
    commission_rate = fields.Float(string='Commission Rate', digits=(5, 4))
    commission_type = fields.Selection(
        selection=[
            ('revenue_share', 'Revenue Share'),
            ('credit',        'Account Credit'),
        ],
        string='Commission Type',
    )
    status = fields.Selection(
        selection=[
            ('pending',   'Pending'),
            ('approved',  'Approved'),
            ('paid',      'Paid'),
            ('cancelled', 'Cancelled'),
            ('flagged',   'Flagged for Review'),
        ],
        string='Status',
        default='pending',
        tracking=True,
    )

    # ── Accruals ──────────────────────────────────────────────────────────────
    accrual_ids = fields.One2many(
        'nbhc.commission.accrual', 'conversion_id', string='Accruals',
    )
    total_accrued = fields.Float(
        string='Total Accrued (EUR)', compute='_compute_total_accrued', store=False,
    )

    def _compute_total_accrued(self):
        for rec in self:
            rec.total_accrued = sum(a.commission_amount for a in rec.accrual_ids)

    # ── XML-RPC hook: called by the Go referral service ───────────────────────
    def create_or_update_by_ref(self, vals_list):
        """Upsert conversion records received from the Go referral service."""
        for vals in vals_list:
            conv_id = vals.get('conversion_id')
            existing = self.search([('conversion_id', '=', conv_id)], limit=1)
            if existing:
                existing.write({k: v for k, v in vals.items() if k != 'conversion_id'})
            else:
                self.create(vals)
        return True
