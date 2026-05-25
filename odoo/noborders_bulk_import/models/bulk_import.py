import hashlib
import logging
import requests
from datetime import timedelta
from odoo import models, fields, api, _
from odoo.exceptions import UserError, ValidationError

_logger = logging.getLogger(__name__)

# ── Enumeration constants ─────────────────────────────────────────────────────
# Values must match backend/bulk-import Go service and iOS Models.swift

AUTHORITY_TYPES = [
    ("ua_mo",          "UA — МО України"),
    ("ua_mvs",         "UA — МВС / НГУ"),
    ("ua_sbu",         "UA — СБУ"),
    ("ua_dsns",        "UA — ДСНС"),
    ("ua_civilian",    "UA — Civilian"),
    ("eu_police",      "EU — National Police"),
    ("eu_gendarmerie", "EU — Gendarmerie (FR/IT/ES/PT)"),
    ("eu_special",     "EU — ATLAS Network"),
    ("eu_civil",       "EU — UCPM Civil Protection"),
    ("eu_border",      "EU — Frontex / Border Guard"),
    ("eu_interpol",    "EU — Interpol Liaison"),
    ("nato",           "NATO — SOFA Covered"),
    ("interpol",       "Interpol — Direct"),
]

IMPORT_TYPES = [
    ("military",   "Military / First Responder"),
    ("corporate",  "Corporate"),
    ("family",     "Family"),
]

BATCH_STATES = [
    ("draft",      "Draft"),
    ("processing", "Processing"),
    ("done",       "Done"),
    ("failed",     "Failed"),
]

LINE_STATES = [
    ("pending",    "Pending"),
    ("activated",  "Activated"),
    ("expired",    "Expired"),
    ("failed",     "Failed"),
]


class NobordersBulkImport(models.Model):
    _name = "nbhc.bulk.import"
    _description = "#nobordershealthcare Bulk Import Batch"
    _inherit = ["mail.thread", "mail.activity.mixin"]
    _order = "create_date desc"

    # ── Core fields ───────────────────────────────────────────────────────────

    name = fields.Char(
        string="Batch Name",
        required=True,
        tracking=True,
    )
    import_type = fields.Selection(
        IMPORT_TYPES,
        string="Import Type",
        required=True,
        default="corporate",
        tracking=True,
    )
    authority = fields.Selection(
        AUTHORITY_TYPES,
        string="Authority",
        required=True,
        default="ua_civilian",
        help="Governs NOK routing and DVI database selection.",
        tracking=True,
    )
    csv_file = fields.Binary(
        string="CSV File",
        attachment=True,
        help=(
            "Military CSV: service_number,nationality,blood_type,phone,"
            "nok_phone,nok_name,authority,role,language\n"
            "Corporate/Family CSV: first_name,last_name,email,phone,"
            "language,plan_tier,profile_type"
        ),
    )
    csv_filename = fields.Char(string="CSV Filename")
    status = fields.Selection(
        BATCH_STATES,
        string="Status",
        default="draft",
        tracking=True,
        readonly=True,
    )
    expiry_days = fields.Integer(
        string="Link Expiry (days)",
        default=7,
        help="Activation links expire after this many days.",
    )

    # ── Stats (computed from lines) ───────────────────────────────────────────

    total_count = fields.Integer(
        string="Total",
        readonly=True,
        compute="_compute_counts",
        store=True,
    )
    activated_count = fields.Integer(
        string="Activated",
        readonly=True,
        compute="_compute_counts",
        store=True,
    )
    pending_count = fields.Integer(
        string="Pending",
        readonly=True,
        compute="_compute_counts",
        store=True,
    )
    failed_count = fields.Integer(
        string="Failed",
        readonly=True,
        compute="_compute_counts",
        store=True,
    )

    # ── Relations ─────────────────────────────────────────────────────────────

    created_by = fields.Many2one(
        "res.users",
        string="Created By",
        default=lambda self: self.env.user,
        readonly=True,
    )
    line_ids = fields.One2many(
        "nbhc.bulk.import.line",
        "import_id",
        string="Import Lines",
    )

    # ── GDPR/LED legal basis confirmation ────────────────────────────────────
    # Logged to blockchain channel2 on upload; must be true before dispatch.

    gdpr_confirmed = fields.Boolean(
        string="Legal Basis Confirmed",
        default=False,
        tracking=True,
        help=(
            "Admin confirms legal basis under GDPR Art.6.1(b)/(c) "
            "or LED Art.8 for law enforcement data."
        ),
    )
    gdpr_confirmed_at = fields.Datetime(string="Confirmed At", readonly=True)
    gdpr_confirmed_by = fields.Many2one(
        "res.users", string="Confirmed By", readonly=True
    )

    # ── Computed fields ───────────────────────────────────────────────────────

    @api.depends("line_ids.status")
    def _compute_counts(self):
        for rec in self:
            lines = rec.line_ids
            rec.total_count = len(lines)
            rec.activated_count = len(lines.filtered(lambda l: l.status == "activated"))
            rec.pending_count = len(lines.filtered(lambda l: l.status == "pending"))
            rec.failed_count = len(lines.filtered(lambda l: l.status == "failed"))

    # ── Actions ───────────────────────────────────────────────────────────────

    def action_confirm_legal_basis(self):
        """Admin confirms GDPR/LED legal basis. Logged to chatter."""
        self.ensure_one()
        self.write({
            "gdpr_confirmed": True,
            "gdpr_confirmed_at": fields.Datetime.now(),
            "gdpr_confirmed_by": self.env.user.id,
        })
        self.message_post(
            body=_(
                "GDPR/LED legal basis confirmed by %(user)s at %(dt)s.",
                user=self.env.user.name,
                dt=fields.Datetime.now(),
            )
        )

    def action_upload_and_dispatch(self):
        """Upload CSV to bulk-import service and dispatch activation invitations."""
        self.ensure_one()
        if not self.gdpr_confirmed:
            raise UserError(
                _("You must confirm GDPR/LED legal basis before dispatching invitations.")
            )
        if not self.csv_file:
            raise UserError(_("Please attach a CSV file before uploading."))

        api_url = (
            self.env["ir.config_parameter"]
            .sudo()
            .get_param(
                "noborders.bulk_import.api_url",
                default="http://bulk-import:8080",
            )
        )

        import base64
        csv_data = base64.b64decode(self.csv_file)

        try:
            resp = requests.post(
                f"{api_url}/bulk/upload",
                files={"csv": (self.csv_filename or "import.csv", csv_data, "text/csv")},
                data={
                    "gdpr_legal_basis_confirmed": "true",
                    "csv_type": self.import_type,
                },
                timeout=60,
            )
            resp.raise_for_status()
        except requests.RequestException as exc:
            raise UserError(_("Upload failed: %s") % str(exc))

        result = resp.json()
        self.write({"status": "processing"})
        self.message_post(
            body=_(
                "Batch %(batch_id)s dispatched — %(queued)d invitations queued.",
                batch_id=result.get("batchID", ""),
                queued=result.get("queued", 0),
            )
        )

    def action_refresh_stats(self):
        """Pull delivery stats from bulk-import service and update line statuses."""
        self.ensure_one()
        api_url = (
            self.env["ir.config_parameter"]
            .sudo()
            .get_param("noborders.bulk_import.api_url", default="http://bulk-import:8080")
        )
        try:
            resp = requests.get(
                f"{api_url}/bulk/stats/{self.name}", timeout=30
            )
            resp.raise_for_status()
        except requests.RequestException as exc:
            _logger.warning("Failed to refresh batch stats for %s: %s", self.name, exc)
            return

        stats = resp.json()
        self.write({
            "activated_count": stats.get("activated", self.activated_count),
            "pending_count":   stats.get("pending",   self.pending_count),
            "failed_count":    stats.get("failed",    self.failed_count),
        })
        if self.total_count > 0 and self.activated_count >= self.total_count:
            self.write({"status": "done"})
            self.message_post(body=_("All invitations activated. Batch complete."))

    def action_resend_failed(self):
        """Re-send invitations to all failed/pending entries."""
        self.ensure_one()
        api_url = (
            self.env["ir.config_parameter"]
            .sudo()
            .get_param("noborders.bulk_import.api_url", default="http://bulk-import:8080")
        )
        try:
            resp = requests.post(
                f"{api_url}/bulk/resend/{self.name}",
                json={"all_failed": True},
                timeout=30,
            )
            resp.raise_for_status()
        except requests.RequestException as exc:
            raise UserError(_("Resend failed: %s") % str(exc))

        queued = resp.json().get("queued", 0)
        self.message_post(
            body=_("Re-send queued for %(n)d entries.", n=queued)
        )

    # ── Automated action helpers (called by ir.cron) ──────────────────────────

    def _cron_send_reminders(self):
        """Day-6 reminder: re-send to all unactivated recipients."""
        cutoff = fields.Datetime.now() - timedelta(days=6)
        batches = self.search([
            ("status", "=", "processing"),
            ("create_date", "<=", cutoff),
        ])
        for batch in batches:
            if batch.pending_count > 0:
                batch.action_resend_failed()

    def _cron_check_completion(self):
        """Mark batches done when all lines are activated."""
        processing = self.search([("status", "=", "processing")])
        for batch in processing:
            batch.action_refresh_stats()


class NobordersBulkImportLine(models.Model):
    _name = "nbhc.bulk.import.line"
    _description = "#nobordershealthcare Bulk Import Line"
    _order = "id asc"

    import_id = fields.Many2one(
        "nbhc.bulk.import",
        string="Batch",
        required=True,
        ondelete="cascade",
        index=True,
    )
    # SHA3-256(phone) only — plaintext phone number is NEVER stored in Odoo.
    phone_hash = fields.Char(
        string="Phone Hash (SHA3-256)",
        required=True,
        help="SHA3-256 of the recipient's phone number. Plaintext is never stored.",
    )
    status = fields.Selection(
        LINE_STATES,
        string="Status",
        default="pending",
        required=True,
        tracking=True,
    )
    # Per-channel delivery flags
    delivery_sms       = fields.Boolean(string="SMS",       default=False)
    delivery_telegram  = fields.Boolean(string="Telegram",  default=False)
    delivery_whatsapp  = fields.Boolean(string="WhatsApp",  default=False)
    delivery_signal    = fields.Boolean(string="Signal",    default=False)
    delivery_viber     = fields.Boolean(string="Viber",     default=False)
    delivery_email     = fields.Boolean(string="Email",     default=False)
    # Timestamps
    activated_at = fields.Datetime(string="Activated At", readonly=True)
    expires_at   = fields.Datetime(string="Expires At",   readonly=True)
    last_resend  = fields.Datetime(string="Last Resend",  readonly=True)
    # Failure info
    failure_reason  = fields.Char(string="Failure Reason", readonly=True)
    failure_channel = fields.Char(string="Failed Channel", readonly=True)
    resend_attempts = fields.Integer(string="Resend Attempts", default=0, readonly=True)

    # ── Constraints ───────────────────────────────────────────────────────────

    @api.constrains("phone_hash")
    def _check_phone_hash(self):
        for rec in self:
            if rec.phone_hash and len(rec.phone_hash) != 64:
                raise ValidationError(
                    _(
                        "phone_hash must be 64 lowercase hex characters (SHA3-256). "
                        "Got length %(n)d for value '%(v)s'",
                        n=len(rec.phone_hash),
                        v=rec.phone_hash[:8] + "...",
                    )
                )

    # ── Helpers ───────────────────────────────────────────────────────────────

    @classmethod
    def _hash_phone(cls, phone: str) -> str:
        """
        Compute SHA3-256(phone) for storage.
        Call this before creating a line — never pass plaintext phone to the model.
        """
        return hashlib.sha3_256(phone.encode("utf-8")).hexdigest()
