# models/referral_code.py — nbhc.referral.code
#
# Mirrors the ReferralCode record from the Go referral service.
# Stored identifier is code_hash (SHA3-256) — the raw code is never stored here.

from odoo import models, fields


class ReferralCode(models.Model):
    _name = 'nbhc.referral.code'
    _description = 'NoBorders Healthcare Referral Code'
    _inherit = ['mail.thread', 'mail.activity.mixin']
    _rec_name = 'code_hash'
    _order = 'created_at desc'

    # ── Identity ─────────────────────────────────────────────────────────────
    code_hash = fields.Char(
        string='Code Hash (SHA3-256)',
        required=True,
        readonly=True,
        index=True,
        help='SHA3-256 hex digest of the referral code. The raw code is never stored in Odoo.',
    )
    referral_type = fields.Selection(
        selection=[
            ('individual', 'Individual (patient → friend)'),
            ('partner',    'Partner (clinic / hospital)'),
            ('affiliate',  'Affiliate (broker / agent)'),
            ('provider',   'Health Provider (lab / pharmacy)'),
        ],
        string='Referral Type',
        required=True,
        tracking=True,
    )

    # ── Referrer ──────────────────────────────────────────────────────────────
    referrer_partner_id = fields.Many2one(
        'res.partner',
        string='Referrer (Partner)',
        ondelete='restrict',
        index=True,
        help='Odoo partner record for the referrer. For individual users this may be left empty.',
    )
    referrer_hash = fields.Char(
        string='Referrer Hash (SHA3-256)',
        readonly=True,
        help='SHA3-256(salt+referrerID) — stored for reconciliation with the Go service.',
    )

    # ── Stripe Connect ────────────────────────────────────────────────────────
    stripe_account = fields.Char(
        string='Stripe Connect Account ID',
        help='acct_... — only for partner and affiliate types.',
    )

    # ── Limits & lifecycle ────────────────────────────────────────────────────
    usage_count = fields.Integer(string='Activations', default=0, readonly=True)
    usage_limit = fields.Integer(
        string='Activation Limit',
        default=10,
        help='10 for individual; -1 = unlimited for partner / affiliate / provider.',
    )
    active = fields.Boolean(string='Active', default=True, tracking=True)
    created_at = fields.Datetime(string='Created At', default=fields.Datetime.now, readonly=True)

    # ── Computed ──────────────────────────────────────────────────────────────
    conversion_ids = fields.One2many(
        'nbhc.referral.conversion', 'code_id', string='Conversions',
    )
    conversion_count = fields.Integer(
        string='Conversion Count', compute='_compute_conversion_count',
    )

    def _compute_conversion_count(self):
        for rec in self:
            rec.conversion_count = len(rec.conversion_ids)

    # ── Constraints ───────────────────────────────────────────────────────────
    _sql_constraints = [
        ('code_hash_uniq', 'unique(code_hash)', 'Code hash must be unique.'),
    ]

    # ── Actions ───────────────────────────────────────────────────────────────
    def action_view_conversions(self):
        self.ensure_one()
        return {
            'type': 'ir.actions.act_window',
            'res_model': 'nbhc.referral.conversion',
            'view_mode': 'list,form',
            'domain': [('code_id', '=', self.id)],
            'context': {'default_code_id': self.id},
        }
