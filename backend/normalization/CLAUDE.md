# Normalization Service — Module Context

## Language: Go 1.22+  |  Hardest engineering problem in the stack

## What this does
Converts raw clinical data (any format) into openEHR Compositions.
UKSH-model semantic layer. Output feeds ScyllaDB CDR.
Applications query via FHIR R4 Search API.

## Pipeline
```
Source (any format) → Kafka WORM staging → Normalization → ScyllaDB CDR → FHIR R4 API
```

## Clinical standards (mandatory)
```go
type LOINCCode  string  // "4548-4" = HbA1c
type SNOMEDCode string  // "46635009" = Type 1 Diabetes
type ATCCode    string  // "A10BA02" = Metformin, "C09AA03" = Lisinopril
type ICD10Code  string  // "E11.9" = Type 2 DM, "I10" = Hypertension

// ATC is PRIMARY for medications — RxNorm is US-only secondary
// If ATC code not found in lookup table → return UNKNOWN, flag for review
// NEVER guess or infer codes using AI
```

## FHIR R4 Search API (application interface)
```
GET /fhir/Observation?patient={hash}&code=4548-4        # HbA1c
GET /fhir/Condition?patient={hash}                       # diagnoses
GET /fhir/MedicationStatement?patient={hash}             # medications
GET /fhir/AllergyIntolerance?patient={hash}              # allergies
GET /fhir/$summary?patient={hash}                        # IPS summary
```

## Kafka staging rules
- Topic: clinical-events-raw
- Key: hash(userID)+":"+hash(docID)  — NO PII in Kafka
- Retention: 7 years (EU clinical data retention)
- Consumers: read-only, no deletion ever

## ATC lookup table (minimum required)
Build a Go map with at minimum these 50+ drugs covering common EU medications.
Start with: Metformin A10BA02, Lisinopril C09AA03, Atorvastatin C10AA05,
Omeprazole A02BC01, Amlodipine C08CA01, Ramipril C09AA05,
Levothyroxine H03AA01, Aspirin B01AC06, Bisoprolol C07AB07,
Paracetamol N02BE01...

## What this service MUST NOT do
- MUST NOT use generative AI to infer or guess clinical codes
- MUST NOT store source documents after staging to Kafka (Kafka = audit copy)
- MUST NOT expose patient identifiers — only hash(userID) in CDR keys
