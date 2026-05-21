package fhir

import (
	"time"

	"github.com/google/uuid"

	"github.com/nobordershealthcare/normalization/cdr"
)

// newBundleID returns a fresh UUID v4 for FHIR Bundle IDs.
func newBundleID() string {
	return uuid.NewString()
}

// nowRFC3339 returns the current UTC time formatted as RFC 3339.
func nowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339)
}

// hashPrefix derives a stable, short FHIR resource ID from the composition's
// SourceHash (SHA3-256 of the originating Kafka EventID).
//
// Using the first 16 chars of SourceHash gives a human-readable, collision-
// resistant identifier that links back to the WORM audit log without exposing
// the full hash in every FHIR response.
func hashPrefix(comp *cdr.Composition) string {
	if len(comp.SourceHash) >= 16 {
		return comp.SourceHash[:16]
	}
	return comp.SourceHash
}
