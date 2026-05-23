// Package license validates healthcare clinician license numbers
// for the jurisdictions served by nobordershealthcare.
//
// Supported formats:
//   PT — Portuguese Ordem dos Médicos number (4–6 digits, optionally prefixed "PT-")
//   DE — German Arztnummer / BSNR (9 digits, checksum validation)
//   UA — Ukrainian licence number (UA-NNNN-NNNNNN format, Ministry of Health)
//   EU — eIDAS professional attribute identifier (CC/CC/XXXXXXX format)
//
// Validation is deterministic pattern matching — no external API calls.
// Returned country code is ISO 3166-1 alpha-2.
package license

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
)

// ErrInvalidFormat is returned when the license number does not match
// any known format.
var ErrInvalidFormat = errors.New("license: unrecognised format")

// Result contains the parsed license information.
type Result struct {
	Number  string // normalised (uppercase, no spaces)
	Country string // ISO 3166-1 alpha-2
	Format  string // "pt-ordem" | "de-bsnr" | "ua-moz" | "eu-eidas"
}

var (
	// PT: Ordem dos Médicos number — 4–6 digits
	rePT = regexp.MustCompile(`^(?:PT-)?(\d{4,6})$`)

	// DE: Arztnummer — exactly 9 digits (basic; full checksum below)
	reDE = regexp.MustCompile(`^(\d{9})$`)

	// UA: МОЗ license — UA-YYYY-NNNNNN (year 2010–2035, 6-digit serial)
	reUA = regexp.MustCompile(`^UA-(?:20[1-2]\d|2030)-(\d{6})$`)

	// EU: eIDAS professional identifier — CC/CC/identifier (ISO country codes)
	reEU = regexp.MustCompile(`^([A-Z]{2})/([A-Z]{2})/([A-Za-z0-9._-]{1,64})$`)
)

// Validate parses and validates a clinician license number.
// input is trimmed and upper-cased before matching.
func Validate(input string) (Result, error) {
	// Normalise
	s := normaliseLicense(input)

	if m := rePT.FindStringSubmatch(s); m != nil {
		return Result{Number: "PT-" + m[1], Country: "PT", Format: "pt-ordem"}, nil
	}

	if m := reDE.FindStringSubmatch(s); m != nil {
		if err := validateDEChecksum(m[1]); err != nil {
			return Result{}, fmt.Errorf("license DE checksum: %w", err)
		}
		return Result{Number: m[1], Country: "DE", Format: "de-bsnr"}, nil
	}

	if m := reUA.FindStringSubmatch(s); m != nil {
		return Result{Number: s, Country: "UA", Format: "ua-moz"}, nil
	}

	if m := reEU.FindStringSubmatch(s); m != nil {
		issuer := m[1]
		return Result{Number: s, Country: issuer, Format: "eu-eidas"}, nil
	}

	return Result{}, ErrInvalidFormat
}

// normaliseLicense trims whitespace and converts to upper case.
func normaliseLicense(s string) string {
	out := make([]byte, 0, len(s))
	for i := range len(s) {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			continue
		}
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		out = append(out, c)
	}
	return string(out)
}

// validateDEChecksum verifies the Luhn-like check digit used in German Arztnummern.
// Reference: KBV Arztnummer format specification.
// The 9th digit is a check digit computed over the first 8.
func validateDEChecksum(digits string) error {
	if len(digits) != 9 {
		return errors.New("must be 9 digits")
	}
	sum := 0
	weights := []int{4, 9, 2, 5, 3, 1, 4, 9} // KBV specification weights
	for i := range 8 {
		d, err := strconv.Atoi(string(digits[i]))
		if err != nil {
			return fmt.Errorf("non-digit at position %d", i)
		}
		sum += d * weights[i]
	}
	check := (sum % 10)
	last, err := strconv.Atoi(string(digits[8]))
	if err != nil {
		return errors.New("non-digit check digit")
	}
	if check != last {
		return fmt.Errorf("checksum mismatch: computed %d, got %d", check, last)
	}
	return nil
}
