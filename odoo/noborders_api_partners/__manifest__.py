# __manifest__.py — Odoo 17 module: NoBorders Healthcare API Partners
#
# Manages healthcare partner API integrations:
#   - Partner registration lifecycle (pending → approved → suspended / revoked)
#   - API key hash storage (SHA3-256 hex — raw key NEVER stored in Odoo)
#   - DSA (Data Sharing Agreement) tracking with 30-day expiry alerts
#   - Monthly API call sync from the Go api-gateway (written via XML-RPC)
#   - Automated draft invoices for billable partners at month-end
#   - Dashboard: kanban by type, API-call graph, DSA expiry timeline
{
    'name': 'NoBorders Healthcare — API Partners',
    'version': '17.0.1.0.0',
    'category': 'Healthcare / Integration',
    'summary': 'Manage healthcare provider API partner registrations and billing',
    'author': 'NoBorders Healthcare',
    'license': 'LGPL-3',
    'depends': [
        'base',
        'mail',       # mail.thread, mail.activity.mixin
        'account',    # draft invoice generation
    ],
    'data': [
        'security/ir.model.access.csv',
        'data/partner_types.xml',
        'views/api_partner_views.xml',
    ],
    'demo': [],
    'installable': True,
    'auto_install': False,
    'application': False,
}
