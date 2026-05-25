package main

import (
	"fmt"
	"os"
)

// bulk-import service — corporate HR / military admin / family organizer
// uploads a CSV of people → system creates PendingProfiles and dispatches
// activation invitations via SMS + Telegram + WhatsApp + Signal + Viber + Email.
//
// HTTP endpoints (served by the api-gateway reverse proxy):
//   POST /bulk/upload    — admin uploads CSV; requires admin JWT + FIDO2 2-person for military
//   GET  /bulk/status/:batchID — admin views delivery telemetry
//   POST /bulk/resend/:entryID — re-send invitation to a specific person
//
// GDPR: admin must confirm legal basis before upload; each recipient gets opt-out on every channel.
// SECURITY: activation tokens are UUID v4 (crypto/rand), stored as SHA3-256(token) in ScyllaDB.

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	srv := newServer()
	fmt.Printf("bulk-import service listening on :%s\n", port)
	if err := srv.ListenAndServe(":" + port); err != nil {
		fmt.Fprintln(os.Stderr, "server error:", err)
		os.Exit(1)
	}
}
