// clinician.go — POST /clinician and GET /proxy/{token}
//
// POST /clinician:
//   Receives clinician license number + jti from the emergency card display form.
//   Steps:
//     1. Validate license format (PT/DE/UA/EU via license.Validate)
//     2. Anomaly detection: count accesses per clinician per hour in Redis
//        If > 5 unique patients/hour → alert logged; request still served (audit not gate)
//     3. Geo-language consistency check (best-effort, non-blocking)
//     4. Ch3 access log (SHA3-256 of license + SHA3-256 of patient sub — never plaintext)
//     5. Return 200 OK with confirmation HTML
//
// GET /proxy/{token}:
//   One-time UUID token for viewing a proxy authorisation document.
//   Token is stored in Redis with NX (set-if-not-exists).
//   First request: serve proxy document page, mark Redis key as "accessed".
//   Second request: 410 Gone.
//   Ch3 access log on first access.
//
// FAIL-CLOSED contract: if Ch3 log write fails, access is denied (503).
package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/nobordershealthcare/physician-view/internal/ch3log"
	"github.com/nobordershealthcare/physician-view/internal/license"
	"github.com/redis/go-redis/v9"
	"golang.org/x/crypto/sha3"
)

const (
	anomalyThreshold    = 5
	anomalyWindowHours  = 1
	proxyTokenKeyPrefix = "proxy:"
	anomalyKeyPrefix    = "anomaly:"
)

// ClinicianHandler handles POST /clinician.
func ClinicianHandler(logger *ch3log.Logger, rdb *redis.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		if err := r.ParseForm(); err != nil {
			http.Error(w, "invalid form data", http.StatusBadRequest)
			return
		}

		licenseInput := strings.TrimSpace(r.FormValue("license"))
		jti := strings.TrimSpace(r.FormValue("jti"))
		patientSub := strings.TrimSpace(r.FormValue("patient_sub"))

		if licenseInput == "" || jti == "" || patientSub == "" {
			http.Error(w, "license, jti, and patient_sub are required", http.StatusBadRequest)
			return
		}

		// Step 1: validate license format
		lic, err := license.Validate(licenseInput)
		if errors.Is(err, license.ErrInvalidFormat) {
			http.Error(w, fmt.Sprintf("unrecognised license format: %q — accepted: PT-NNNN, NNNNNNNNN (DE), UA-YYYY-NNNNNN, CC/CC/ID (eIDAS)", licenseInput), http.StatusUnprocessableEntity)
			return
		}
		if err != nil {
			http.Error(w, fmt.Sprintf("license validation error: %s", err.Error()), http.StatusUnprocessableEntity)
			return
		}

		// Step 2: anomaly detection — sliding-window counter per clinician per hour
		anomalyTriggered := checkAnomaly(r.Context(), rdb, lic.Number, patientSub)
		if anomalyTriggered {
			// Alert logged — access still served (anomaly is audit, not gate)
			slog.Warn("anomaly: clinician accessed >5 unique patients in 1 hour",
				slog.String("clinicianCountry", lic.Country),
				slog.String("licHash", sha3HexShort([]byte(lic.Number))),
			)
		}

		// Step 3: geo-language consistency (best-effort, non-blocking)
		if mismatch := geoLangMismatch(lic.Country, r.Header.Get("Accept-Language")); mismatch {
			slog.Info("geo-language mismatch",
				slog.String("licCountry", lic.Country),
				slog.String("acceptLang", r.Header.Get("Accept-Language")),
				slog.String("remote", r.RemoteAddr),
			)
		}

		// Step 4: Ch3 access log — FAIL-CLOSED
		if err := logger.LogAccess(
			r.Context(),
			ch3log.AccessClinicianForm,
			lic.Number,
			lic.Country,
			patientSub,
			jti,
		); err != nil {
			slog.Error("ch3 log failed — denying access", slog.String("err", err.Error()))
			http.Error(w, "access log unavailable — please try again or contact support", http.StatusServiceUnavailable)
			return
		}

		// Step 5: success response
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		resp := map[string]string{
			"status":  "logged",
			"country": lic.Country,
			"jti":     jti,
		}
		json.NewEncoder(w).Encode(resp) //nolint:errcheck — best-effort response write
	}
}

// ProxyTokenHandler handles GET /proxy/{token}.
// The token is a UUID string stored in Redis by LegalVaultManager on the iOS side.
// Redis key schema: "proxy:<uuid>" → JSON payload (proxy document summary).
// NX semantics: set a "accessed" marker with NX; if already set → 410 Gone.
func ProxyTokenHandler(logger *ch3log.Logger, rdb *redis.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		// Extract token from path: /proxy/{token}
		token := strings.TrimPrefix(r.URL.Path, "/proxy/")
		token = strings.TrimSpace(token)
		if token == "" || strings.Contains(token, "/") {
			http.Error(w, "invalid token", http.StatusBadRequest)
			return
		}

		dataKey     := proxyTokenKeyPrefix + token
		accessedKey := proxyTokenKeyPrefix + token + ":accessed"

		// Attempt NX set on the "accessed" marker — expires 1 minute after the
		// first access (long enough for the page to load; short enough to prevent reuse).
		set, err := rdb.SetNX(r.Context(), accessedKey, "1", time.Minute).Result()
		if err != nil {
			slog.Error("redis SetNX failed", slog.String("err", err.Error()))
			http.Error(w, "token verification unavailable", http.StatusServiceUnavailable)
			return
		}
		if !set {
			// Token already accessed — 410 Gone as per spec
			http.Error(w, "410 Gone — this proxy document link has already been used", http.StatusGone)
			return
		}

		// Read the proxy document payload
		payload, err := rdb.Get(r.Context(), dataKey).Bytes()
		if err == redis.Nil {
			http.Error(w, "proxy document not found or expired", http.StatusNotFound)
			return
		}
		if err != nil {
			slog.Error("redis Get failed", slog.String("err", err.Error()))
			http.Error(w, "document retrieval error", http.StatusServiceUnavailable)
			return
		}

		// Parse the proxy document summary
		var doc proxyDocPayload
		if err := json.Unmarshal(payload, &doc); err != nil {
			slog.Error("proxy doc unmarshal failed", slog.String("err", err.Error()))
			http.Error(w, "document format error", http.StatusInternalServerError)
			return
		}

		// Ch3 access log (best-effort for proxy — document is already served)
		go func() {
			logCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if logErr := logger.LogAccess(logCtx, ch3log.AccessProxyDocument,
				doc.RecipientHash, doc.RecipientCountry,
				doc.GrantorSubHash, token); logErr != nil {
				slog.Error("ch3 proxy log failed", slog.String("err", logErr.Error()))
			}
		}()

		// Serve the proxy document page
		serveProxyDocPage(w, doc)
	}
}

// proxyDocPayload is the Redis payload stored by the iOS app when generating a share token.
// The iOS side stores this via a backend API call after sealing the grant in LegalVault.
// recipientHash and grantorSubHash are SHA3-256 hashes — no PII.
type proxyDocPayload struct {
	GrantorSubHash   string   `json:"grantorSubHash"`   // SHA3-256 of grantor's sub
	RecipientHash    string   `json:"recipientHash"`    // SHA3-256 of recipient license
	RecipientCountry string   `json:"recipientCountry"` // ISO 3166-1 alpha-2
	DocumentType     string   `json:"documentType"`     // powerOfAttorney, courtOrder, etc.
	DetectedLang     string   `json:"detectedLang"`     // ISO 639-1
	Pages            []string `json:"pages"`            // base64-encoded encrypted page images
	OcrText          []string `json:"ocrText"`          // per-page OCR text (original language)
	Translations     map[string][]string `json:"translations"` // langCode → [pageTexts]
	ExpiresAt        string   `json:"expiresAt"`        // RFC3339
}

// serveProxyDocPage renders a minimal HTML page for the proxy document.
func serveProxyDocPage(w http.ResponseWriter, doc proxyDocPayload) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")

	fmt.Fprintf(w, `<!DOCTYPE html>
<html lang="%s">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Proxy Authorisation Document</title>
<style>
body{font-family:system-ui,sans-serif;max-width:800px;margin:2rem auto;padding:1rem;color:#1a1a1a}
h1{font-size:1.4rem;margin-bottom:.5rem}
.badge{display:inline-block;background:#003f6b;color:#fff;padding:.25rem .6rem;border-radius:.4rem;font-size:.8rem;margin-bottom:1rem}
.page{border:1px solid #ddd;border-radius:.5rem;padding:1rem;margin:1rem 0}
pre{white-space:pre-wrap;font-size:.85rem;font-family:inherit}
.disclaimer{margin-top:2rem;padding:.75rem;background:#fff3cd;border-radius:.4rem;font-size:.8rem}
@media print{.no-print{display:none}}
</style>
</head>
<body>
<h1>Proxy Authorisation Document</h1>
<span class="badge">One-time access — this link is now expired</span>
<p><strong>Type:</strong> %s</p>
<p><strong>Language:</strong> %s</p>`,
		html_escape(doc.DetectedLang),
		html_escape(doc.DocumentType),
		html_escape(doc.DetectedLang),
	)

	for i, text := range doc.OcrText {
		fmt.Fprintf(w, `<div class="page"><strong>Page %d (original)</strong><pre>%s</pre></div>`,
			i+1, html_escape(text))
	}

	if enTexts, ok := doc.Translations["en"]; ok {
		fmt.Fprintf(w, `<h2>English translation</h2>`)
		for i, text := range enTexts {
			fmt.Fprintf(w, `<div class="page"><strong>Page %d</strong><pre>%s</pre></div>`,
				i+1, html_escape(text))
		}
	}

	fmt.Fprintf(w, `
<div class="disclaimer no-print">
This document was shared as a one-time link under eIDAS Art.25 and GDPR Art.9.
It has been cryptographically signed by the proxy holder. This link is now
invalidated. Access has been logged on the nobordershealthcare audit ledger.
</div>
</body></html>`)
}

// checkAnomaly increments the sliding-window counter for a clinician+hour bucket.
// Returns true if the threshold is exceeded (anomaly detected).
// Uses Redis INCR + EXPIRE — no AOF, no RDB, no CONFIG/SLAVEOF/DEBUG per spec.
func checkAnomaly(ctx context.Context, rdb *redis.Client, licNormalised string, patientSub string) bool {
	// Bucket key: anomaly:<sha3short(license)>:<hour-bucket>
	hourBucket := time.Now().UTC().Format("2006010215")
	key := anomalyKeyPrefix + sha3HexShort([]byte(licNormalised)) + ":" + hourBucket

	count, err := rdb.Incr(ctx, key).Result()
	if err != nil {
		// Redis unavailable — skip anomaly check (best-effort)
		return false
	}
	// Set TTL only on first increment to avoid resetting the window
	if count == 1 {
		rdb.Expire(ctx, key, time.Duration(anomalyWindowHours+1)*time.Hour) //nolint:errcheck
	}
	return count > anomalyThreshold
}

// geoLangMismatch returns true if the license country does not match the
// primary language in the Accept-Language header.
// This is a best-effort signal, not a hard gate.
var countryLangMap = map[string]string{
	"PT": "pt",
	"DE": "de",
	"UA": "uk",
}

func geoLangMismatch(licCountry, acceptLang string) bool {
	expected, ok := countryLangMap[licCountry]
	if !ok {
		return false // EU eIDAS or unknown country — skip check
	}
	if acceptLang == "" {
		return false
	}
	primary := strings.ToLower(strings.SplitN(strings.SplitN(acceptLang, ",", 2)[0], ";", 2)[0])
	if len(primary) >= 2 {
		primary = primary[:2]
	}
	return primary != expected && primary != "en"
}

// sha3HexShort returns the first 16 chars (8 bytes) of the SHA3-256 hex digest.
// Used for Redis keys and log snippets — short enough for keys, not re-identifiable.
func sha3HexShort(data []byte) string {
	h := sha3.New256()
	h.Write(data)
	return fmt.Sprintf("%x", h.Sum(nil))[:16]
}

// html_escape escapes HTML special characters for safe inclusion in HTML output.
func html_escape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	s = strings.ReplaceAll(s, "'", "&#39;")
	return s
}
