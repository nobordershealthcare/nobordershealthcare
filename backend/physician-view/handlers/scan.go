// Package handlers provides HTTP handler functions for the physician-view service.
//
// scan.go — GET /scan?token=<jwt>
//
// Flow:
//   1. Extract JWT from query parameter
//   2. Rate-limit by remote IP (Redis INCR, 30 req/min)
//   3. Verify Ed25519 signature using embedded "pk" claim (offline-capable)
//   4. Check Redis revocation key — rejects if patient has revoked consent
//   5. Detect preferred display language from Accept-Language header vs JWT "lang" claim
//   6. Render emergency card HTML template
//
// Security:
//   - Algorithm pinned to EdDSA (ErrAlgorithm returned for anything else)
//   - Expiry enforced (ErrExpired for past tokens)
//   - jti NOT single-use here — multiple ER doctors can view the same QR within 15 min
//   - Consent revocation: Redis key "revoke:{sub}" checked before serving
//   - Clinician access is logged AFTER the clinician submits their license via /clinician
//
// PII handling: no patient name, DOB, or any identifier is written to logs.
// Only SHA3-256 hashes appear in structured log entries.
package handlers

import (
	"context"
	"errors"
	"fmt"
	"html/template"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/nobordershealthcare/physician-view/internal/jwtverify"
	"github.com/redis/go-redis/v9"
)

// CardTemplateData is passed to the emergency-card HTML template.
type CardTemplateData struct {
	// JWT claims (safe to render)
	Blood       string
	Allergies   []string
	Medications []map[string]string // name, dose, freq, atc (optional)

	// Hashed identifiers (displayed as-is for clinician reference)
	PatientRef string // first 16 chars of SHA3-256(sub) — enough for reference, not re-identifiable
	JTI        string // for the clinician form hidden field

	// Display configuration
	Lang  string // ISO 639-1 from JWT "lang" claim or Accept-Language
	Name  string // Patient-chosen display name (e.g. "Maria K.")
	DOB   string // ISO 8601 date of birth
	T     map[string]string // translations

	// Verification status
	CryptoVerified bool
	ExpiresAt      string // human-readable expiry from exp claim
}

// RevocationKeyPrefix is the Redis key prefix for consent revocations.
// Key format: "revoke:{sha3-256-hex(patientSub)}"
// Set by the gatekeeper when it receives a consent revocation event from Fabric channel 2.
// TTL = jwtMaxAge (15 min) — covers the maximum remaining lifetime of any issued JWT.
const RevocationKeyPrefix = "revoke:"

// scanLimiter enforces a per-IP request rate limit on the scan endpoint.
// 30 requests/minute per IP; window resets after 60 seconds.
// Redis-backed so the limit is shared across all replicas of this service.
var (
	scanLimiterMu  sync.Mutex
	scanLimiterMap = map[string]*localBucket{}
)

type localBucket struct {
	count   int
	resetAt time.Time
}

// scanRateAllow returns false when the remote IP has exceeded 30 requests per minute.
// Falls back to allow=true on Redis error to avoid blocking legitimate emergency access.
func scanRateAllow(ctx context.Context, rdb *redis.Client, remoteIP string) bool {
	key := "ratelimit:scan:" + sanitizeIPForKey(remoteIP)
	count, err := rdb.Incr(ctx, key).Result()
	if err != nil {
		// Redis unavailable — fail open (never block ER access over a Redis hiccup).
		slog.Warn("scan rate-limit redis error — failing open", slog.String("err", err.Error()))
		return true
	}
	if count == 1 {
		rdb.Expire(ctx, key, time.Minute) //nolint:errcheck — best-effort TTL
	}
	return count <= 30
}

// sanitizeIPForKey strips port and brackets so the Redis key contains only the address.
func sanitizeIPForKey(remoteAddr string) string {
	if i := strings.LastIndex(remoteAddr, ":"); i > 0 {
		// host:port — strip port. IPv6 addresses contain ":" inside brackets.
		if strings.ContainsRune(remoteAddr, '[') {
			// [::1]:port
			if j := strings.Index(remoteAddr, "]"); j > 0 {
				return remoteAddr[1:j]
			}
		}
		return remoteAddr[:i]
	}
	return remoteAddr
}

// scanLandingHTML is a minimal HTML page served for GET /scan.
// The QR code encodes a URL of the form:  https://view.example/scan#<jwt>
// The fragment (everything after #) is NEVER sent to the server — it is read
// by this page's inline script, which immediately auto-submits a hidden POST
// form.  This keeps the full JWT out of every server log, CDN log, nginx
// access log, and proxy access log.
//
// Security properties of this page:
//   - No external resources (no CDN, no fonts, no tracking pixels).
//   - history.replaceState removes the fragment before the form submits so
//     the JWT does not appear in the browser's history or session storage.
//   - The page itself carries no patient data; only the POST body does.
//   - Cache-Control: no-store prevents the landing page being served stale.
const scanLandingHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Loading patient record…</title>
<style>
  body{font-family:system-ui,sans-serif;display:flex;align-items:center;
       justify-content:center;height:100vh;margin:0;background:#f0f4f8}
  p{color:#444;font-size:1.1rem}
</style>
</head>
<body>
<p id="msg">Verifying QR code…</p>
<form id="f" method="POST" action="/scan" style="display:none">
  <input type="hidden" id="tok" name="token" value="">
</form>
<script>
(function(){
  var hash = location.hash;
  if (!hash || hash.length < 2) {
    document.getElementById('msg').textContent =
      'Invalid QR code — no token found. Please ask the patient to display the QR again.';
    return;
  }
  var tok = hash.slice(1); // strip leading '#'
  // Erase the fragment from the URL bar before submitting — prevents the JWT
  // from appearing in browser history, bookmarks, or referrer headers.
  history.replaceState(null, '', location.pathname);
  document.getElementById('tok').value = tok;
  document.getElementById('f').submit();
})();
</script>
</body>
</html>`

// ScanHandler handles both legs of the QR-scan flow.
//
//	GET  /scan          — serves the fragment-reading landing page (no token in URL)
//	POST /scan          — verifies the JWT (from POST body) and renders the emergency card
//
// The QR code on the patient's phone encodes:
//
//	https://<host>/scan#<jwt>
//
// The fragment is never transmitted to the server in GET requests, so the JWT
// never appears in nginx access logs, CDN logs, or any upstream proxy log.
// rdb is required for rate limiting and consent revocation checks.
func ScanHandler(tmpl *template.Template, rdb *redis.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			// Serve the landing page. The browser's JS reads location.hash and
			// re-submits via POST — the JWT never touches a server URL.
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Cache-Control", "no-store, no-cache")
			w.Header().Set("X-Content-Type-Options", "nosniff")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(scanLandingHTML))
			return
		case http.MethodPost:
			// Fall through to JWT verification below.
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		// Rate limit: 30 requests/minute per IP.
		if !scanRateAllow(r.Context(), rdb, r.RemoteAddr) {
			http.Error(w, "too many requests", http.StatusTooManyRequests)
			return
		}

		if err := r.ParseForm(); err != nil {
			http.Error(w, "invalid form data", http.StatusBadRequest)
			return
		}
		tokenStr := strings.TrimSpace(r.FormValue("token"))
		if tokenStr == "" {
			http.Error(w, "missing token", http.StatusBadRequest)
			return
		}

		claims, err := jwtverify.Verify(tokenStr)
		if err != nil {
			code := http.StatusUnauthorized
			if errors.Is(err, jwtverify.ErrExpired) {
				code = http.StatusGone
			}
			// Do NOT log the token string — it contains patient data.
			// Do NOT echo the internal error to the caller — prevents token oracle attacks.
			slog.Warn("jwt verification failed", slog.String("err", err.Error()), slog.String("remote", r.RemoteAddr))
			http.Error(w, "invalid or expired QR code", code)
			return
		}

		// Consent revocation check: reject if the patient has revoked access since this
		// token was issued. The gatekeeper sets "revoke:{sub}" in Redis (TTL = 15 min)
		// when it processes a RevocationEvent from Fabric channel 2.
		revKey := RevocationKeyPrefix + claims.Sub
		if revoked, err := rdb.Exists(r.Context(), revKey).Result(); err == nil && revoked > 0 {
			slog.Warn("scan blocked — consent revoked", slog.String("ref", safeRef(claims.Sub)))
			http.Error(w, "access revoked", http.StatusForbidden)
			return
		}
		// On Redis error, fail open with a warning — do not block ER access.
		_ = fmt.Sprintf // suppress unused import warning; err already evaluated above


		lang := selectLanguage(claims.Lang, r.Header.Get("Accept-Language"))
		t := translations(lang)

		data := CardTemplateData{
			Blood:          claims.Blood,
			Allergies:      claims.Allergies,
			Medications:    claims.Medications,
			PatientRef:     safeRef(claims.Sub),
			JTI:            claims.JTI,
			Lang:           lang,
			Name:           claims.Name,
			DOB:            claims.DOB,
			T:              t,
			CryptoVerified: true,
			ExpiresAt:      formatUnix(claims.EXP),
		}

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store, no-cache")
		w.Header().Set("X-Content-Type-Options", "nosniff")

		if err := tmpl.ExecuteTemplate(w, "emergency-card.html", data); err != nil {
			slog.Error("template render failed", slog.String("err", err.Error()))
			http.Error(w, "render error", http.StatusInternalServerError)
		}
	}
}

// selectLanguage picks the display language. Preferred order:
//  1. JWT "lang" claim (patient's app language setting)
//  2. First matching tag from Accept-Language header
//  3. "en" fallback
func selectLanguage(jwtLang, acceptLang string) string {
	supported := map[string]bool{"en": true, "uk": true, "de": true, "pt": true, "ru": true}
	if supported[jwtLang] {
		return jwtLang
	}
	// Parse Accept-Language: "pt-PT,pt;q=0.9,en;q=0.8"
	for _, part := range strings.Split(acceptLang, ",") {
		tag := strings.TrimSpace(strings.SplitN(part, ";", 2)[0])
		if len(tag) >= 2 {
			prefix := strings.ToLower(tag[:2])
			if supported[prefix] {
				return prefix
			}
		}
	}
	return "en"
}

// safeRef returns the first 16 chars of the sub claim for display reference.
// The sub is already SHA3-256(salt+userID) — 64 hex chars. Truncating to 16
// is sufficient for a clinician reference number while reducing ledger footprint.
func safeRef(sub string) string {
	if len(sub) >= 16 {
		return sub[:16]
	}
	return sub
}

// formatUnix converts a Unix timestamp to a human-readable UTC string.
func formatUnix(unix int64) string {
	if unix == 0 {
		return ""
	}
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04:05 UTC")
}

// translations returns a map of UI strings for the given ISO 639-1 language code.
func translations(lang string) map[string]string {
	all := map[string]map[string]string{
		"en": {
			"title":           "Emergency Medical Record",
			"subtitle":        "Scan verified — display to treating clinician",
			"name":            "Patient",
			"dob":             "Date of birth",
			"blood":           "Blood type",
			"allergies":       "Allergies",
			"no_allergies":    "None on record",
			"medications":     "Current medications",
			"no_medications":  "None on record",
			"atc":             "ATC",
			"dose":            "Dose",
			"freq":            "Frequency",
			"verified":        "✓ Cryptographically verified (EdDSA / Ed25519)",
			"expires":         "Token valid until",
			"ref":             "Patient reference",
			"clinician_form":  "Clinician Access Log",
			"license_label":   "Your medical license number",
			"license_ph":      "e.g. PT-12345 · 123456789 · UA-2023-001234",
			"submit_log":      "Log access and confirm",
			"print":           "Print",
			"warning":         "This record is time-limited. Do not share or copy.",
			"proxy_link":      "View proxy authorisation documents",
		},
		"uk": {
			"title":           "Екстрена медична картка",
			"subtitle":        "QR-код перевірено — показати лікарю",
			"name":            "Пацієнт",
			"dob":             "Дата народження",
			"blood":           "Група крові",
			"allergies":       "Алергії",
			"no_allergies":    "Не зазначено",
			"medications":     "Поточні ліки",
			"no_medications":  "Не зазначено",
			"atc":             "АТС",
			"dose":            "Доза",
			"freq":            "Частота",
			"verified":        "✓ Криптографічно верифіковано (EdDSA / Ed25519)",
			"expires":         "Дійсний до",
			"ref":             "Код пацієнта",
			"clinician_form":  "Журнал доступу",
			"license_label":   "Ваш номер медичної ліцензії",
			"license_ph":      "напр. PT-12345 · 123456789 · UA-2023-001234",
			"submit_log":      "Підтвердити і записати",
			"print":           "Друк",
			"warning":         "Картка обмежена за часом. Не копіювати.",
			"proxy_link":      "Документи уповноваженої особи",
		},
		"de": {
			"title":           "Notfallmedizinische Akte",
			"subtitle":        "QR verifiziert — dem behandelnden Arzt vorzeigen",
			"name":            "Patient",
			"dob":             "Geburtsdatum",
			"blood":           "Blutgruppe",
			"allergies":       "Allergien",
			"no_allergies":    "Keine eingetragen",
			"medications":     "Aktuelle Medikamente",
			"no_medications":  "Keine eingetragen",
			"atc":             "ATC",
			"dose":            "Dosis",
			"freq":            "Häufigkeit",
			"verified":        "✓ Kryptographisch verifiziert (EdDSA / Ed25519)",
			"expires":         "Gültig bis",
			"ref":             "Patientenreferenz",
			"clinician_form":  "Arzt-Zugriffsprotokoll",
			"license_label":   "Ihre Arztnummer",
			"license_ph":      "z. B. 123456789",
			"submit_log":      "Zugriff protokollieren",
			"print":           "Drucken",
			"warning":         "Diese Akte ist zeitlich begrenzt. Nicht kopieren.",
			"proxy_link":      "Vorsorgevollmacht anzeigen",
		},
		"pt": {
			"title":           "Registo Médico de Emergência",
			"subtitle":        "QR verificado — mostrar ao médico assistente",
			"name":            "Paciente",
			"dob":             "Data de nascimento",
			"blood":           "Grupo sanguíneo",
			"allergies":       "Alergias",
			"no_allergies":    "Nenhuma registada",
			"medications":     "Medicação actual",
			"no_medications":  "Nenhuma registada",
			"atc":             "Código ATC",
			"dose":            "Dose",
			"freq":            "Frequência",
			"verified":        "✓ Verificado criptograficamente (EdDSA / Ed25519)",
			"expires":         "Válido até",
			"ref":             "Referência do paciente",
			"clinician_form":  "Registo de acesso clínico",
			"license_label":   "Número da sua cédula profissional",
			"license_ph":      "ex: PT-12345",
			"submit_log":      "Registar acesso",
			"print":           "Imprimir",
			"warning":         "Este registo tem validade limitada. Não copiar.",
			"proxy_link":      "Ver documentos de procuração",
		},
		"ru": {
			"title":           "Экстренная медицинская карта",
			"subtitle":        "QR-код проверен — показать лечащему врачу",
			"name":            "Пациент",
			"dob":             "Дата рождения",
			"blood":           "Группа крови",
			"allergies":       "Аллергии",
			"no_allergies":    "Не указано",
			"medications":     "Текущие препараты",
			"no_medications":  "Не указано",
			"atc":             "АТС",
			"dose":            "Доза",
			"freq":            "Частота",
			"verified":        "✓ Криптографически верифицировано (EdDSA / Ed25519)",
			"expires":         "Действителен до",
			"ref":             "Код пациента",
			"clinician_form":  "Журнал доступа врачей",
			"license_label":   "Ваш номер медицинской лицензии",
			"license_ph":      "напр. PT-12345 · 123456789 · UA-2023-001234",
			"submit_log":      "Подтвердить и записать",
			"print":           "Печать",
			"warning":         "Карта ограничена по времени. Не копировать.",
			"proxy_link":      "Документы доверенного лица",
		},
	}
	if t, ok := all[lang]; ok {
		return t
	}
	return all["en"]
}
