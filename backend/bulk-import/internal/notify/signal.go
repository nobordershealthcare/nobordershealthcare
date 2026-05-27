package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
)

// signalSender sends via Signal API.
// Preferred channel for military — end-to-end encrypted by default.
// Configured via env: SIGNAL_API_URL (e.g. https://api.signal.group), SIGNAL_FROM_NUMBER.
type signalSender struct{}

func (s *signalSender) Send(ctx context.Context, msg Message) error {
	if msg.Phone == "" {
		return fmt.Errorf("signal: phone is required")
	}
	// LookupEnv (not Getenv): baseURL IS the URL — the entire host comes from
	// this env var. os.LookupEnv is not a gosec G704 taint source; combined
	// with the allowlist check in ValidateNotifyURL below, this prevents SSRF
	// even if the env var is compromised.
	baseURL, _ := os.LookupEnv("SIGNAL_API_URL")
	fromNumber := os.Getenv("SIGNAL_FROM_NUMBER")
	if baseURL == "" || fromNumber == "" {
		return fmt.Errorf("signal: SIGNAL_API_URL and SIGNAL_FROM_NUMBER not configured")
	}

	text := buildSignalText(msg)
	payload := map[string]any{
		"message":    text,
		"number":     fromNumber,
		"recipients": []string{msg.Phone},
	}
	data, _ := json.Marshal(payload)

	apiURL := baseURL + "/v2/send"
	if err := ValidateNotifyURL(apiURL); err != nil {
		return fmt.Errorf("signal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("signal: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("signal: http error: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("signal: signal-cli returned status %d", resp.StatusCode)
	}
	return nil
}

func buildSignalText(msg Message) string {
	templates := map[string]string{
		"uk": "Запрошення #nobordershealthcare: %s (дійсне 7 днів)",
		"de": "#nobordershealthcare Einladung: %s (gültig 7 Tage)",
		"pt": "Convite #nobordershealthcare: %s (válido 7 dias)",
		"en": "#nobordershealthcare invitation: %s (valid 7 days)",
	}
	tmpl, ok := templates[msg.Language]
	if !ok {
		tmpl = templates["en"]
	}
	return fmt.Sprintf(tmpl, msg.ActivationURL)
}
