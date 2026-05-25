{
    "name": "#nobordershealthcare Bulk Import",
    "version": "19.0.1.0.0",
    "summary": "Batch activation of military/corporate/family health profiles",
    "description": """
Manages bulk CSV import of users, dispatches activation invitations
via SMS / Telegram / WhatsApp / Signal / Viber / Email, and tracks
activation rates on a Kanban dashboard.

GDPR/LED: admin must confirm legal basis before upload.
Phone numbers stored as SHA3-256 hash only — never plaintext.

Supports:
  • Military (STANAG 2154) — UA МО, EU Gendarmerie, NATO
  • Corporate — company employee onboarding
  • Family — family-member onboarding

Requires: noborders_api_partners (API-key config, mTLS credentials)
    """,
    "author": "NoBorders Healthcare",
    "website": "https://noborders.healthcare",
    "category": "Health",
    "depends": ["base", "mail", "contacts", "noborders_api_partners"],
    "data": [
        "security/ir.model.access.csv",
        "views/bulk_import_views.xml",
        "views/bulk_import_menus.xml",
    ],
    # Automated actions wired up via ir.cron records below (data file kept
    # separate so they can be disabled without uninstalling the module).
    # Triggers:
    #   1. Day 6 of batch: reminder SMS/email to unactivated recipients.
    #   2. Failed delivery > 3 attempts: create support activity.
    #   3. All activated: mark batch done, notify admin by chatter post.
    "license": "LGPL-3",
    "installable": True,
    "application": False,
    "auto_install": False,
}
