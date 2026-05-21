-- CDR (Clinical Data Repository) — ScyllaDB CQL schema
-- All partition keys are SHA3-256(userID): 64 lowercase hex chars.
-- All clustering keys use SHA3-256(docID): 64 lowercase hex chars.
-- No plaintext patient identifiers appear anywhere in this schema.
--
-- TTL: 315 360 000 s ≈ 10 years (EU MDR minimum medical record retention).
-- Compaction: LeveledCompactionStrategy (read-heavy FHIR query workload).
-- Compression: LZ4 (fast decompression for blob reads).
--
-- Health records are APPEND-ONLY. "Deletion" is revocation at the smart
-- contract layer — encrypted blobs remain on disk until TTL expiry.

CREATE KEYSPACE IF NOT EXISTS cdr
    WITH replication = {
        'class': 'NetworkTopologyStrategy',
        'EU_WEST': '3'           -- minimum 3 replicas within the EU region
    }
    AND durable_writes = true;

-- ── Table 1: main CDR table ───────────────────────────────────────────────────
-- Write target. One row per normalized clinical document.
-- Access pattern: fetch a specific document by (user_hash, doc_hash).
CREATE TABLE IF NOT EXISTS cdr.compositions (
    user_hash         text,       -- SHA3-256(userID), 64 hex chars
    doc_hash          text,       -- SHA3-256(docID),  64 hex chars
    composition_type  text,       -- 'observation' | 'condition' |
                                  -- 'medication_statement' | 'allergy_intolerance'
    loinc_code        text,       -- populated for observations; null otherwise
    atc_code          text,       -- populated for medication_statements; null otherwise
    icd10_code        text,       -- populated for conditions; null otherwise
    snomed_code       text,       -- populated for allergies; null otherwise
    source_hash       text,       -- SHA3-256(Kafka EventID) — audit linkage to WORM log
    encrypted_blob    blob,       -- AES-256-GCM openEHR Composition (12-byte nonce prepended)
    schema_version    smallint,   -- internal blob schema version for migration
    review_required   boolean,    -- true if any code was resolved as UNKNOWN
    created_at        timestamp,
    PRIMARY KEY (user_hash, doc_hash)
) WITH CLUSTERING ORDER BY (doc_hash ASC)
  AND compaction  = {'class': 'LeveledCompactionStrategy'}
  AND compression = {'sstable_compression': 'LZ4Compressor'}
  AND default_time_to_live = 315360000
  AND comment = 'Main CDR write target. One row per normalized composition.';

-- ── Table 2: compositions indexed by type ────────────────────────────────────
-- Access pattern: GET /fhir/Condition, /MedicationStatement, /AllergyIntolerance
-- All columns duplicated from cdr.compositions (denormalized for query efficiency).
CREATE TABLE IF NOT EXISTS cdr.compositions_by_type (
    user_hash         text,
    composition_type  text,
    doc_hash          text,
    loinc_code        text,
    atc_code          text,
    icd10_code        text,
    snomed_code       text,
    source_hash       text,
    encrypted_blob    blob,
    schema_version    smallint,
    review_required   boolean,
    created_at        timestamp,
    PRIMARY KEY (user_hash, composition_type, doc_hash)
) WITH CLUSTERING ORDER BY (composition_type ASC, doc_hash ASC)
  AND compaction  = {'class': 'LeveledCompactionStrategy'}
  AND compression = {'sstable_compression': 'LZ4Compressor'}
  AND default_time_to_live = 315360000
  AND comment = 'Index by composition_type for FHIR resource-type queries.';

-- ── Table 3: observations indexed by LOINC code ──────────────────────────────
-- Access pattern: GET /fhir/Observation?patient={hash}&code={loinc}
CREATE TABLE IF NOT EXISTS cdr.observations_by_loinc (
    user_hash      text,
    loinc_code     text,
    doc_hash       text,
    source_hash    text,
    encrypted_blob blob,
    schema_version smallint,
    review_required boolean,
    created_at     timestamp,
    PRIMARY KEY (user_hash, loinc_code, doc_hash)
) WITH CLUSTERING ORDER BY (loinc_code ASC, doc_hash ASC)
  AND compaction  = {'class': 'LeveledCompactionStrategy'}
  AND compression = {'sstable_compression': 'LZ4Compressor'}
  AND default_time_to_live = 315360000
  AND comment = 'Index by LOINC code for Observation search.';
