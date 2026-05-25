// Package notify provides multi-channel activation invitation dispatch.
// Each function is independent; a failure in one channel does not block others.
// SECURITY: activation URLs contain UUID v4 tokens — treat as secrets in transit.
// GDPR: every message includes an opt-out instruction ("reply STOP" for SMS).
package notify

import "context"

// Message is the normalised notification payload passed to every channel sender.
// Phone and Email may be empty if the channel does not apply.
type Message struct {
	Phone         string // E.164
	Email         string
	Language      string // ISO 639-1 — drives template selection
	ActivationURL string // https://app.noborders.healthcare/activate/{token}
	DisplayName   string // "John S." — omitted for military profiles
	ProfileType   string // "military" | "corporate" | "family"
}

// Sender is the common interface for all notification channels.
type Sender interface {
	Send(ctx context.Context, msg Message) error
}

// SendSMS dispatches via Twilio / GatewayAPI. Primary channel for military.
func SendSMS(ctx context.Context, msg Message) error      { return smsClient.Send(ctx, msg) }

// SendTelegram dispatches via Telegram Bot API.
func SendTelegram(ctx context.Context, msg Message) error { return telegramClient.Send(ctx, msg) }

// SendWhatsApp dispatches via WhatsApp Business API (pre-approved template).
func SendWhatsApp(ctx context.Context, msg Message) error { return whatsappClient.Send(ctx, msg) }

// SendSignal dispatches via signal-cli (encrypted — preferred for military).
func SendSignal(ctx context.Context, msg Message) error   { return signalClient.Send(ctx, msg) }

// SendViber dispatches via Viber Business API.
func SendViber(ctx context.Context, msg Message) error    { return viberClient.Send(ctx, msg) }

// SendEmail dispatches via SMTP/SendGrid fallback.
func SendEmail(ctx context.Context, msg Message) error    { return emailClient.Send(ctx, msg) }

// ─── Singleton clients (configured from env vars at startup) ─────────────────

var (
	smsClient      Sender = &smsSender{}
	telegramClient Sender = &telegramSender{}
	whatsappClient Sender = &whatsappSender{}
	signalClient   Sender = &signalSender{}
	viberClient    Sender = &viberSender{}
	emailClient    Sender = &emailSender{}
)
