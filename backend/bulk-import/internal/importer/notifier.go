package importer

import (
	"context"
	"sync"
	"time"

	"github.com/nobordershealthcare/bulk-import/internal/notify"
)

// dispatchAll sends activation invitations via all available channels in parallel.
// SMS is the primary channel for military (no internet required in the field).
// Rate limit: max 1000 SMS per minute via token bucket in sms.go.
func dispatchAll(ctx context.Context, profiles []*PendingProfile) {
	const smsRatePerMin = 1000

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
			sendToProfile(ctx, p, semSMS)
		}()
	}
	wg.Wait()
}

func sendToProfile(ctx context.Context, p *PendingProfile, smsSem chan struct{}) {
	msg := notify.Message{
		Phone:         p.Phone,
		Email:         p.Email,
		Language:      p.Language,
		ActivationURL: p.ActivationURL,
		DisplayName:   p.DisplayName,
		ProfileType:   p.ProfileType,
	}

	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		smsSem <- struct{}{}
		err := notify.SendSMS(ctx, msg)
		updateDeliveryStatus(ctx, p.ID, "sms", err)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		err := notify.SendTelegram(ctx, msg)
		updateDeliveryStatus(ctx, p.ID, "telegram", err)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		err := notify.SendWhatsApp(ctx, msg)
		updateDeliveryStatus(ctx, p.ID, "whatsapp", err)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		err := notify.SendSignal(ctx, msg)
		updateDeliveryStatus(ctx, p.ID, "signal", err)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		err := notify.SendViber(ctx, msg)
		updateDeliveryStatus(ctx, p.ID, "viber", err)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		err := notify.SendEmail(ctx, msg)
		updateDeliveryStatus(ctx, p.ID, "email", err)
	}()

	wg.Wait()
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
