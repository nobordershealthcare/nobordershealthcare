package importer

import (
	"encoding/csv"
	"fmt"
	"io"
	"strings"
)

// ImportRow is the normalised output of parsing either CSV variant.
type ImportRow struct {
	// Shared fields
	Phone    string // E.164
	Language string // ISO 639-1

	// Corporate / family
	FirstName string
	LastName  string
	Email     string
	PlanTier  string // "standard" | "premium"

	// Military
	ServiceNumber string
	Nationality   string // ISO 3166-1 alpha-2
	BloodType     string
	NOKPhone      string // E.164
	NOKName       string

	CSVType string // "military" | "corporate" | "family"
}

// ParseCSV parses either a military CSV or a corporate/family CSV.
// csvType: "military" | "corporate" | "family"
func ParseCSV(r io.Reader, filename, csvType string) ([]ImportRow, error) {
	reader := csv.NewReader(r)
	reader.TrimLeadingSpace = true

	headers, err := reader.Read()
	if err != nil {
		return nil, fmt.Errorf("cannot read CSV headers: %w", err)
	}
	headerIdx := make(map[string]int, len(headers))
	for i, h := range headers {
		headerIdx[strings.ToLower(strings.TrimSpace(h))] = i
	}

	switch csvType {
	case "military":
		return parseMilitaryCSV(reader, headerIdx)
	case "corporate", "family":
		return parseCorporateCSV(reader, headerIdx, csvType)
	default:
		return nil, fmt.Errorf("unknown csv_type %q — must be 'military', 'corporate', or 'family'", csvType)
	}
}

func parseMilitaryCSV(reader *csv.Reader, idx map[string]int) ([]ImportRow, error) {
	required := []string{"service_number", "nationality", "blood_type", "phone", "nok_phone", "nok_name"}
	for _, col := range required {
		if _, ok := idx[col]; !ok {
			return nil, fmt.Errorf("military CSV missing required column %q", col)
		}
	}

	var rows []ImportRow
	lineNum := 2
	for {
		record, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("line %d: CSV read error: %w", lineNum, err)
		}
		row := ImportRow{
			ServiceNumber: strings.TrimSpace(record[idx["service_number"]]),
			Nationality:   strings.ToUpper(strings.TrimSpace(record[idx["nationality"]])),
			BloodType:     strings.TrimSpace(record[idx["blood_type"]]),
			Phone:         strings.TrimSpace(record[idx["phone"]]),
			NOKPhone:      strings.TrimSpace(record[idx["nok_phone"]]),
			NOKName:       strings.TrimSpace(record[idx["nok_name"]]),
			Language:      "en",
			CSVType:       "military",
		}
		if err := ValidateRow(row); err != nil {
			return nil, fmt.Errorf("line %d: %w", lineNum, err)
		}
		rows = append(rows, row)
		lineNum++
	}
	return rows, nil
}

func parseCorporateCSV(reader *csv.Reader, idx map[string]int, csvType string) ([]ImportRow, error) {
	required := []string{"first_name", "last_name", "email", "phone"}
	for _, col := range required {
		if _, ok := idx[col]; !ok {
			return nil, fmt.Errorf("%s CSV missing required column %q", csvType, col)
		}
	}

	var rows []ImportRow
	lineNum := 2
	for {
		record, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("line %d: CSV read error: %w", lineNum, err)
		}
		lang := "en"
		if i, ok := idx["language"]; ok && i < len(record) {
			if v := strings.TrimSpace(record[i]); v != "" {
				lang = v
			}
		}
		planTier := "standard"
		if i, ok := idx["plan_tier"]; ok && i < len(record) {
			if v := strings.TrimSpace(record[i]); v != "" {
				planTier = v
			}
		}
		row := ImportRow{
			FirstName: strings.TrimSpace(record[idx["first_name"]]),
			LastName:  strings.TrimSpace(record[idx["last_name"]]),
			Email:     strings.TrimSpace(record[idx["email"]]),
			Phone:     strings.TrimSpace(record[idx["phone"]]),
			Language:  lang,
			PlanTier:  planTier,
			CSVType:   csvType,
		}
		if err := ValidateRow(row); err != nil {
			return nil, fmt.Errorf("line %d: %w", lineNum, err)
		}
		rows = append(rows, row)
		lineNum++
	}
	return rows, nil
}
