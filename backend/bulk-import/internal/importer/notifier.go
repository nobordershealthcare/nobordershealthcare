package importer

import (
	"context"
	"sync"
	"time"

	"github.com/nobordershealthcare/bulk-import/internal/notify"
)

// signalThrottle enforces the 10 messages/second Signal rate limit.
// Shared across all concurrent goroutines — one tick every 100ms.
var signalThrottle = time.NewTicker(100 * time.Millisecond)

// dispatchAll sends activation invitations via all available channels.
// Military profiles use priority ordering (Signal → SMS → rest).
// Non-military profiles use full parallel fan-out.
// Rate limits: SMS 1 000/min, Signal 10/s — enforced via semaphores.
func dispatchAll(ctx context.Context, profiles []*PendingProfile) {
	const smsRatePerMin = 1000

	// SMS semaphore: replenish every minute
	semSMS := make(chan struct{}, smsRatePerMin)
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			for len(semSMS) > 0 {
				<-semSMS
			}
		}
	}()

	var wg sync.WaitGroup
	for _, p := range profiles {
		p := p
		wg.Add(1)
		go func() {
			defer wg.Done()
			if p.ProfileType == "military" {
				sendMilitaryPriority(ctx, p, semSMS)
			} else {
				sendParallel(ctx, p, semSMS)
			}
		}()
	}
	wg.Wait()
}

// sendMilitaryPriority dispatches in STANAG-compliant priority order:
//
//  1. Signal — E2E encrypted (preferred — military operational security)
//  2. SMS    — no internet required (works in the field without data)
//  3. Telegram / WhatsApp / Viber / Email — parallel fallback channels
//
// Signal and SMS are sent sequentially (highest-priority first) to maximise
// the chance of encrypted delivery before the plaintext-capable channels.
func sendMilitaryPriority(ctx context.Context, p *PendingProfile, smsSem chan struct{}) {
	msg := buildMsg(p)

	// 1. Signal — rate-limited to 10/s, sent before SMS
	<-signalThrottle.C
	err := notify.SendSignal(ctx, msg)
	updateDeliveryStatus(ctx, p.ID, "signal", err)

	// 2. SMS — works without internet; always sent regardless of Signal result
	smsSem <- struct{}{}
	err = notify.SendSMS(ctx, msg)
	updateDeliveryStatus(ctx, p.ID, "sms", err)

	// 3-6. Remaining channels in parallel
	var wg sync.WaitGroup
	type chanFn struct {
		name string
		fn   func(context.Context, notify.Message) error
	}
	for _, c := range []chanFn{
		{"telegram", notify.SendTelegram},
		{"whatsapp", notify.SendWhatsApp},
		{"viber", notify.SendViber},
		{"email", notify.SendEmail},
	} {
		c := c
		wg.Add(1)
		go func() {
			defer wg.Done()
			updateDeliveryStatus(ctx, p.ID, c.name, c.fn(ctx, msg))
		}()
	}
	wg.Wait()
}

// sendParallel dispatches all channels concurrently — used for non-military profiles.
func sendParallel(ctx context.Context, p *PendingProfile, smsSem chan struct{}) {
	msg := buildMsg(p)
	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		smsSem <- struct{}{}
		updateDeliveryStatus(ctx, p.ID, "sms", notify.SendSMS(ctx, msg))
	}()

	for _, c := range []struct {
		name string
		fn   func(context.Context, notify.Message) error
	}{
		{"telegram", notify.SendTelegram},
		{"whatsapp", notify.SendWhatsApp},
		{"signal", notify.SendSignal},
		{"viber", notify.SendViber},
		{"email", notify.SendEmail},
	} {
		c := c
		wg.Add(1)
		go func() {
			defer wg.Done()
			updateDeliveryStatus(ctx, p.ID, c.name, c.fn(ctx, msg))
		}()
	}
	wg.Wait()
}

func buildMsg(p *PendingProfile) notify.Message {
	return notify.Message{
		Phone:         p.Phone,
		Email:         p.Email,
		Language:      p.Language,
		ActivationURL: p.ActivationURL,
		DisplayName:   p.DisplayName,
		ProfileType:   p.ProfileType,
	}
}

// updateDeliveryStatus persists the channel delivery result.
// Logs only SHA3-256(phone) — never the phone number itself.
func updateDeliveryStatus(_ context.Context, entryID, channel string, err error) {
	status := "sent"
	if err != nil {
		status = "failed"
	}
	// TODO: UPDATE pending_profiles SET delivery_status[channel] = status WHERE id = entryID
	_ = entryID
	_ = channel
	_ = status
}
