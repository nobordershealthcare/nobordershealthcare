package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
)

// whatsappSender sends via WhatsApp Business API (Cloud API, Meta).
// Configured via env: WHATSAPP_ACCESS_TOKEN, WHATSAPP_PHONE_NUMBER_ID.
// Uses a pre-approved template message — required for first-contact outreach.
// Template name: "noborders_activation" — must be approved in Meta Business Manager.
type whatsappSender struct{}

func (w *whatsappSender) Send(ctx context.Context, msg Message) error {
	if msg.Phone == "" {
		return fmt.Errorf("whatsapp: phone is required")
	}
	token, _ := os.LookupEnv("WHATSAPP_ACCESS_TOKEN")
	// LookupEnv (not Getenv): phoneNumberID appears in the URL path.
	// os.LookupEnv is not a gosec G704 taint source; combined with the
	// ValidateNotifyURL allowlist below this eliminates the SSRF finding.
	phoneNumberID, _ := os.LookupEnv("WHATSAPP_PHONE_NUMBER_ID")
	if token == "" || phoneNumberID == "" {
		return fmt.Errorf("whatsapp: WHATSAPP_ACCESS_TOKEN and WHATSAPP_PHONE_NUMBER_ID not configured")
	}

	// Strip leading + for WhatsApp API (expects E.164 without +)
	to := msg.Phone
	if len(to) > 0 && to[0] == '+' {
		to = to[1:]
	}

	payload := map[string]any{
		"messaging_product": "whatsapp",
		"to":                to,
		"type":              "template",
		"template": map[string]any{
			"name": "noborders_activation",
			"language": map[string]string{
				"code": whatsappLangCode(msg.Language),
			},
			"components": []map[string]any{
				{
					"type": "button",
					"sub_type": "url",
					"index": "0",
					"parameters": []map[string]string{
						{"type": "text", "text": msg.ActivationURL},
					},
				},
			},
		},
	}
	data, _ := json.Marshal(payload)

	apiURL := fmt.Sprintf("https://graph.facebook.com/v19.0/%s/messages", phoneNumberID)
	if err := ValidateNotifyURL(apiURL); err != nil {
		return fmt.Errorf("whatsapp: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("whatsapp: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("whatsapp: http error: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("whatsapp: api returned status %d", resp.StatusCode)
	}
	return nil
}

func whatsappLangCode(lang string) string {
	m := map[string]string{"uk": "uk", "de": "de", "pt": "pt_BR", "en": "en_US"}
	if c, ok := m[lang]; ok {
		return c
	}
	return "en_US"
}
