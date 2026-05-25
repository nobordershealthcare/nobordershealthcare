package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
)

// emailSender sends via SendGrid API.
// Configured via env: SENDGRID_API_KEY, SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME.
// Always includes a plain-text fallback alongside the HTML version (accessibility).
// GDPR: includes unsubscribe link on every message.
type emailSender struct{}

func (e *emailSender) Send(ctx context.Context, msg Message) error {
	if msg.Email == "" {
		return nil // email is optional — skip silently
	}
	apiKey := os.Getenv("SENDGRID_API_KEY")
	fromEmail := os.Getenv("SENDGRID_FROM_EMAIL")
	fromName := os.Getenv("SENDGRID_FROM_NAME")
	if apiKey == "" || fromEmail == "" {
		return fmt.Errorf("email: SENDGRID_API_KEY and SENDGRID_FROM_EMAIL not configured")
	}
	if fromName == "" {
		fromName = "NoBorders Healthcare"
	}

	subject, htmlBody, textBody := buildEmailContent(msg)
	payload := map[string]any{
		"personalizations": []map[string]any{
			{"to": []map[string]string{{"email": msg.Email}}},
		},
		"from":    map[string]string{"email": fromEmail, "name": fromName},
		"subject": subject,
		"content": []map[string]string{
			{"type": "text/plain", "value": textBody},
			{"type": "text/html", "value": htmlBody},
		},
	}
	data, _ := json.Marshal(payload)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.sendgrid.com/v3/mail/send", bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("email: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("email: http error: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("email: sendgrid returned status %d", resp.StatusCode)
	}
	return nil
}

func buildEmailContent(msg Message) (subject, html, text string) {
	type tmpl struct{ subject, html, text string }
	templates := map[string]tmpl{
		"uk": {
			subject: "Запрошення до #nobordershealthcare",
			html:    `<h2>Ваш медичний профіль надзвичайних ситуацій</h2><p>Вас запрошено активувати захищений профіль.</p><p><a href="%s" style="background:#2D5BFF;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;">Активувати профіль</a></p><p style="font-size:12px;color:#999;">Для відписки перейдіть за посиланням: <a href="%s/unsubscribe">відписатись</a></p>`,
			text:    "Активуйте профіль: %s\nВідписатись: %s/unsubscribe",
		},
		"de": {
			subject: "Einladung zu #nobordershealthcare",
			html:    `<h2>Ihr Notfall-Gesundheitsprofil</h2><p>Sie wurden eingeladen, ein sicheres Profil zu aktivieren.</p><p><a href="%s" style="background:#2D5BFF;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;">Profil aktivieren</a></p><p style="font-size:12px;color:#999;"><a href="%s/unsubscribe">Abmelden</a></p>`,
			text:    "Profil aktivieren: %s\nAbmelden: %s/unsubscribe",
		},
		"pt": {
			subject: "Convite para o #nobordershealthcare",
			html:    `<h2>O seu perfil de saúde de emergência</h2><p>Foi convidado para ativar um perfil seguro.</p><p><a href="%s" style="background:#2D5BFF;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;">Ativar perfil</a></p><p style="font-size:12px;color:#999;"><a href="%s/unsubscribe">Cancelar subscrição</a></p>`,
			text:    "Ativar perfil: %s\nCancelar: %s/unsubscribe",
		},
		"en": {
			subject: "Invitation to #nobordershealthcare",
			html:    `<h2>Your Emergency Health Profile</h2><p>You have been invited to activate a secure emergency health profile.</p><p><a href="%s" style="background:#2D5BFF;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;">Activate profile</a></p><p style="font-size:12px;color:#999;"><a href="%s/unsubscribe">Unsubscribe</a></p>`,
			text:    "Activate your profile: %s\nUnsubscribe: %s/unsubscribe",
		},
	}
	t, ok := templates[msg.Language]
	if !ok {
		t = templates["en"]
	}
	base := "https://app.noborders.healthcare"
	return t.subject,
		fmt.Sprintf(t.html, msg.ActivationURL, base),
		fmt.Sprintf(t.text, msg.ActivationURL, base)
}
