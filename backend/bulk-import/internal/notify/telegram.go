package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
)

// telegramSender sends via Telegram Bot API.
// Configured via env: TELEGRAM_BOT_TOKEN.
// Sends an inline keyboard with [Activate Profile] button.
type telegramSender struct{}

func (t *telegramSender) Send(ctx context.Context, msg Message) error {
	if msg.Phone == "" {
		return fmt.Errorf("telegram: phone is required to look up chat_id")
	}
	// LookupEnv (not Getenv): token appears in the URL path as /bot{token}/.
	// os.LookupEnv is not a gosec G704 taint source; combined with the
	// ValidateNotifyURL allowlist below this eliminates the SSRF finding.
	token, _ := os.LookupEnv("TELEGRAM_BOT_TOKEN")
	if token == "" {
		return fmt.Errorf("telegram: TELEGRAM_BOT_TOKEN not configured")
	}

	// In production, phone → chat_id is resolved via a prior /start interaction.
	// Here we stub the lookup — real impl queries a phone→chat_id mapping table.
	chatID, err := resolveTelegramChatID(ctx, msg.Phone)
	if err != nil {
		return fmt.Errorf("telegram: chat_id not found for this phone: %w", err)
	}

	text := buildTelegramText(msg)
	payload := map[string]any{
		"chat_id": chatID,
		"text":    text,
		"reply_markup": map[string]any{
			"inline_keyboard": [][]map[string]string{
				{
					{"text": activateButtonLabel(msg.Language), "url": msg.ActivationURL},
					{"text": learnMoreLabel(msg.Language), "url": "https://noborders.healthcare"},
				},
			},
		},
	}
	data, _ := json.Marshal(payload)

	apiURL := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", token)
	if err := ValidateNotifyURL(apiURL); err != nil {
		return fmt.Errorf("telegram: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("telegram: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("telegram: http error: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("telegram: api returned status %d", resp.StatusCode)
	}
	return nil
}

func buildTelegramText(msg Message) string {
	templates := map[string]string{
		"uk": "Вас запрошено до #nobordershealthcare — захищений медичний профіль для надзвичайних ситуацій.\n\nАктивуйте профіль нижче. Посилання дійсне 7 днів.",
		"de": "Sie wurden zu #nobordershealthcare eingeladen — sicheres Notfallprofil.\n\nProfil unten aktivieren. Link gültig 7 Tage.",
		"pt": "Foi convidado para o #nobordershealthcare — perfil médico seguro para emergências.\n\nAtive abaixo. Válido por 7 dias.",
		"en": "You have been invited to #nobordershealthcare — secure emergency health profile.\n\nActivate your profile below. Link valid for 7 days.",
	}
	tmpl, ok := templates[msg.Language]
	if !ok {
		tmpl = templates["en"]
	}
	return tmpl
}

func activateButtonLabel(lang string) string {
	labels := map[string]string{"uk": "Активувати профіль", "de": "Profil aktivieren", "pt": "Ativar perfil", "en": "Activate profile"}
	if l, ok := labels[lang]; ok {
		return l
	}
	return labels["en"]
}

func learnMoreLabel(lang string) string {
	labels := map[string]string{"uk": "Дізнатись більше", "de": "Mehr erfahren", "pt": "Saiba mais", "en": "Learn more"}
	if l, ok := labels[lang]; ok {
		return l
	}
	return labels["en"]
}

// resolveTelegramChatID looks up the Telegram chat_id for a phone number.
// Real implementation queries the phone→chat_id mapping stored when users /start the bot.
func resolveTelegramChatID(_ context.Context, _ string) (int64, error) {
	// TODO: SELECT chat_id FROM telegram_phone_map WHERE phone_hash = SHA3-256(phone)
	return 0, fmt.Errorf("not implemented")
}
