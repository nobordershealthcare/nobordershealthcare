package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
)

// viberSender sends via Viber Business API.
// Configured via env: VIBER_AUTH_TOKEN, VIBER_SENDER_NAME.
// Sends a rich message with a CTA button.
type viberSender struct{}

func (v *viberSender) Send(ctx context.Context, msg Message) error {
	if msg.Phone == "" {
		return fmt.Errorf("viber: phone is required")
	}
	token, _ := os.LookupEnv("VIBER_AUTH_TOKEN")
	senderName, _ := os.LookupEnv("VIBER_SENDER_NAME")
	if token == "" {
		return fmt.Errorf("viber: VIBER_AUTH_TOKEN not configured")
	}
	if senderName == "" {
		senderName = "NoBordersHealth"
	}

	text := buildViberText(msg)
	payload := map[string]any{
		"receiver": msg.Phone,
		"type":     "rich_media",
		"sender": map[string]string{
			"name": senderName,
		},
		"rich_media": map[string]any{
			"Type":                "rich_media",
			"ButtonsGroupColumns": 6,
			"ButtonsGroupRows":    2,
			"BgColor":             "#FFFFFF",
			"Buttons": []map[string]any{
				{
					"Columns":    6,
					"Rows":       1,
					"Text":       text,
					"TextSize":   "medium",
					"ActionType": "none",
				},
				{
					"Columns":    6,
					"Rows":       1,
					"Text":       activateButtonLabel(msg.Language),
					"TextSize":   "medium",
					"ActionType": "open-url",
					"ActionBody": msg.ActivationURL,
					"BgColor":    "#2D5BFF",
					"TextColor":  "#FFFFFF",
				},
			},
		},
	}
	data, _ := json.Marshal(payload)

	const viberURL = "https://chatapi.viber.com/pa/send_message"
	if err := ValidateNotifyURL(viberURL); err != nil {
		return fmt.Errorf("viber: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, viberURL, bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("viber: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Viber-Auth-Token", token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("viber: http error: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("viber: api returned status %d", resp.StatusCode)
	}
	return nil
}

func buildViberText(msg Message) string {
	templates := map[string]string{
		"uk": "Вас запрошено до #nobordershealthcare. Активуйте свій захищений медичний профіль.",
		"de": "Sie wurden zu #nobordershealthcare eingeladen. Aktivieren Sie Ihr sicheres Gesundheitsprofil.",
		"pt": "Foi convidado para o #nobordershealthcare. Ative o seu perfil de saúde seguro.",
		"en": "You have been invited to #nobordershealthcare. Activate your secure health profile.",
	}
	tmpl, ok := templates[msg.Language]
	if !ok {
		tmpl = templates["en"]
	}
	return tmpl
}
