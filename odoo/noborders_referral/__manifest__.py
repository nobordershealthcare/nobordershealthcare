# __manifest__.py — Odoo 19 module: NoBorders Healthcare Referral Management
#
# Manages the 4-type referral programme:
#   TYPE 1 — Individual (patient → friend):   account credit, no cash
#   TYPE 2 — Partner (clinic/hospital):       15% lifetime commission via Stripe Connect
#   TYPE 3 — Affiliate (broker):              20%→10%→5% tiered via Stripe Connect
#   TYPE 4 — Health Provider (lab/pharmacy):  API call credits
#
# Privacy note: referred_hash is SHA3-256(salt+userID) — no PII stored in Odoo.
{
    'name': 'NoBorders Healthcare — Referral Management',
    'version': '19.0.1.0.0',
    'category': 'Healthcare / Marketing',
    'summary': '4-type referral programme: individual credits, partner/affiliate Stripe commissions, provider API credits',
    'author': 'NoBorders Healthcare',
    'license': 'LGPL-3',
    'depends': [
        'base',
        'mail',     # mail.thread, mail.activity.mixin
        'account',  # draft invoice generation for commissions
    ],
    'data': [
        'security/ir.model.access.csv',
        'views/referral_views.xml',
        'views/dashboard.xml',
        'data/automated_actions.xml',
    ],
    'assets': {},
    'installable': True,
    'auto_install': False,
    'application': False,
}
