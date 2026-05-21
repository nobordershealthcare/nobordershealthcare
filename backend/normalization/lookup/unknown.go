package lookup

// IsUnknown returns true if the string is the sentinel unknown value.
// Works for any code type that has been cast to string.
func IsUnknown(code string) bool {
	return code == UnknownCode
}

// ResolveATC looks up an ATC code by drug name.
// Returns (UnknownCode, ReviewFlag) if the drug is not in the table.
// Never guesses, never calls external APIs.
func ResolveATC(drugName, eventID, userHash, docHash string) (ATCCode, *ReviewFlag) {
	if code, ok := LookupATC(drugName); ok {
		return code, nil
	}
	return UnknownCode, &ReviewFlag{
		EventID:     eventID,
		UserHash:    userHash,
		DocHash:     docHash,
		UnknownCode: drugName,
		CodeSystem:  CodeSystemATC,
	}
}

// ResolveLOINC looks up a LOINC code.
// Returns (UnknownCode, ReviewFlag) if the code is not in the table.
func ResolveLOINC(code LOINCCode, eventID, userHash, docHash string) (LOINCEntry, *ReviewFlag) {
	if entry, ok := LookupLOINC(code); ok {
		return entry, nil
	}
	return LOINCEntry{}, &ReviewFlag{
		EventID:     eventID,
		UserHash:    userHash,
		DocHash:     docHash,
		UnknownCode: string(code),
		CodeSystem:  CodeSystemLOINC,
	}
}

// ResolveSNOMED looks up a SNOMED CT code.
// Returns (UnknownCode, ReviewFlag) if the code is not in the table.
func ResolveSNOMED(code SNOMEDCode, eventID, userHash, docHash string) (SNOMEDEntry, *ReviewFlag) {
	if entry, ok := LookupSNOMED(code); ok {
		return entry, nil
	}
	return SNOMEDEntry{}, &ReviewFlag{
		EventID:     eventID,
		UserHash:    userHash,
		DocHash:     docHash,
		UnknownCode: string(code),
		CodeSystem:  CodeSystemSNOMED,
	}
}

// ResolveICD10 validates format and looks up an ICD-10 code.
// Returns (UnknownCode, ReviewFlag) for format failures or missing entries.
func ResolveICD10(code ICD10Code, eventID, userHash, docHash string) (ICD10Entry, *ReviewFlag) {
	if !ValidateICD10Format(code) {
		return ICD10Entry{}, &ReviewFlag{
			EventID:     eventID,
			UserHash:    userHash,
			DocHash:     docHash,
			UnknownCode: string(code),
			CodeSystem:  CodeSystemICD10,
		}
	}
	if entry, ok := LookupICD10(code); ok {
		return entry, nil
	}
	// Format is valid but not in our table — still needs review.
	return ICD10Entry{Code: code, Display: UnknownCode}, &ReviewFlag{
		EventID:     eventID,
		UserHash:    userHash,
		DocHash:     docHash,
		UnknownCode: string(code),
		CodeSystem:  CodeSystemICD10,
	}
}
