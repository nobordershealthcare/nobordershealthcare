package importer

import (
	"fmt"
	"regexp"
	"strings"
)

var e164Re = regexp.MustCompile(`^\+[1-9]\d{6,14}$`)

// ValidateRow validates a single parsed CSV row.
// Returns an error describing the first invalid field found.
func ValidateRow(row ImportRow) error {
	if row.Phone == "" {
		return fmt.Errorf("phone is required")
	}
	if !e164Re.MatchString(row.Phone) {
		return fmt.Errorf("phone %q is not valid E.164 format", row.Phone)
	}

	switch row.CSVType {
	case "military":
		if row.ServiceNumber == "" {
			return fmt.Errorf("service_number is required for military rows")
		}
		if len(row.Nationality) != 2 {
			return fmt.Errorf("nationality %q must be ISO 3166-1 alpha-2", row.Nationality)
		}
		if row.BloodType == "" {
			return fmt.Errorf("blood_type is required for military rows")
		}
		if row.NOKPhone != "" && !e164Re.MatchString(row.NOKPhone) {
			return fmt.Errorf("nok_phone %q is not valid E.164 format", row.NOKPhone)
		}
	case "corporate", "family":
		if strings.TrimSpace(row.FirstName) == "" {
			return fmt.Errorf("first_name is required")
		}
		if strings.TrimSpace(row.LastName) == "" {
			return fmt.Errorf("last_name is required")
		}
		if row.Email == "" {
			return fmt.Errorf("email is required")
		}
		if !strings.Contains(row.Email, "@") {
			return fmt.Errorf("email %q is not valid", row.Email)
		}
	}
	return nil
}

// Deduplicate removes duplicate rows by phone number.
// For military rows it deduplicates by service_number instead.
func Deduplicate(rows []ImportRow) []ImportRow {
	seen := make(map[string]bool, len(rows))
	out := make([]ImportRow, 0, len(rows))
	for _, r := range rows {
		key := r.Phone
		if r.CSVType == "military" && r.ServiceNumber != "" {
			key = r.ServiceNumber
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, r)
	}
	return out
}
