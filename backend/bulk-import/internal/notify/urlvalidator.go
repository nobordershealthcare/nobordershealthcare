package notify

import (
	"fmt"
	"net/url"
	"strings"
)

// allowedHosts is the closed allowlist of external notification API endpoints.
// Any URL that does not resolve to one of these hosts is rejected before the
// HTTP request is built — preventing SSRF regardless of how the URL was constructed.
var allowedHosts = map[string]bool{
	"api.twilio.com":     true, // SMS (Twilio)
	"api.telegram.org":   true, // Telegram Bot API
	"graph.facebook.com": true, // WhatsApp Business (Meta Cloud API)
	"chatapi.viber.com":  true, // Viber Business API
	"api.signal.group":   true, // Signal API
	"api.sendgrid.com":   true, // SendGrid email API
	"smtp.sendgrid.net":  true, // SendGrid SMTP (reserved)
}

// ValidateNotifyURL returns an error if rawURL is not a valid HTTPS URL whose
// host is in the allowedHosts allowlist.  Call this before every
// http.NewRequestWithContext in the notify package.
func ValidateNotifyURL(rawURL string) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("notify: invalid URL: %w", err)
	}
	if u.Scheme != "https" {
		return fmt.Errorf("notify: URL must use HTTPS, got %q", u.Scheme)
	}
	host := strings.ToLower(u.Hostname())
	if !allowedHosts[host] {
		return fmt.Errorf("notify: host %q is not in the allowlist", host)
	}
	return nil
}
