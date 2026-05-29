package diia

import (
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"mime"
	"mime/multipart"
	"net/http"
	"strings"
	"time"

	"golang.org/x/crypto/sha3"
)

// maxCallbackBody caps the multipart body to 16 MiB.
// A CAdES-BES signature over a document hash is small, but we allow room
// for multiple files plus metadata.
const maxCallbackBody = 16 << 20 // 16 MiB

// ── ASN.1 OIDs ────────────────────────────────────────────────────────────

var (
	oidSignedData      = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 2}
	oidECDSAWithSHA256 = asn1.ObjectIdentifier{1, 2, 840, 10045, 4, 3, 2}
)

// ── CMS / CAdES-BES ASN.1 structures (RFC 5652) ───────────────────────────

// contentInfo is the outer CMS ContentInfo wrapper.
type contentInfo struct {
	ContentType asn1.ObjectIdentifier
	Content     asn1.RawValue `asn1:"explicit,tag:0"`
}

// encapContentInfo describes the encapsulated content type.
type encapContentInfo struct {
	EContentType asn1.ObjectIdentifier
	EContent     asn1.RawValue `asn1:"optional,explicit,tag:0"`
}

// signedData is a CMS SignedData structure (RFC 5652 §5.1).
// Certificates and CRLs are optional IMPLICIT tagged fields; Go's asn1 package
// handles them correctly by tag matching during sequential decode.
type signedData struct {
	Version          int                        `asn1:"default:1"`
	DigestAlgorithms []pkix.AlgorithmIdentifier `asn1:"set"`
	EncapContentInfo encapContentInfo
	Certificates     asn1.RawValue   `asn1:"optional,tag:0"` // [0] IMPLICIT CertificateSet
	CRLs             asn1.RawValue   `asn1:"optional,tag:1"` // [1] IMPLICIT RevocationInfoChoices
	SignerInfos      []signerInfoASN `asn1:"set"`
}

// signerInfoASN is a CMS SignerInfo structure (RFC 5652 §5.3).
// SignedAttrs uses IMPLICIT [0] tagging on the wire; the raw value is
// preserved so we can re-tag it to SET (0x31) before hashing per §5.4.
type signerInfoASN struct {
	Version            int                      `asn1:"default:1"`
	SID                asn1.RawValue            // IssuerAndSerialNumber or SubjectKeyIdentifier
	DigestAlgorithm    pkix.AlgorithmIdentifier
	SignedAttrs        asn1.RawValue            `asn1:"optional,tag:0"` // IMPLICIT [0] → re-tag to SET for hashing
	SignatureAlgorithm pkix.AlgorithmIdentifier
	Signature          []byte
	UnsignedAttrs      asn1.RawValue            `asn1:"optional,tag:1"` // IMPLICIT [1]
}

// ecdsaSigValue is the DER structure inside SignerInfo.signature for ECDSA.
type ecdsaSigValue struct {
	R *big.Int
	S *big.Int
}

// ── StoreInterface ────────────────────────────────────────────────────────

// StoreInterface is the subset of Store operations required by HandleSignCallback.
// *Store satisfies this interface. Tests inject a mock implementation.
type StoreInterface interface {
	GetRequest(ctx context.Context, requestID string) (*SignRequestMeta, error)
	SaveResult(ctx context.Context, result VerifyResult) error
}

// ── Callback meta ────────────────────────────────────────────────────────

// callbackMeta is the JSON body of the "meta" multipart field.
// Diia sends this alongside each signed file in the callback POST.
type callbackMeta struct {
	RequestID string `json:"requestId"`
	BranchID  string `json:"branchId,omitempty"`
	OfferID   string `json:"offerId,omitempty"`
	FileKey   string `json:"fileKey,omitempty"`
	FileName  string `json:"fileName,omitempty"`
}

// ── Handler factory ───────────────────────────────────────────────────────

// HandleSignCallback returns an http.HandlerFunc that processes Diia.Підпис
// signing callbacks.
//
// Flow:
//  1. Parse multipart/form-data body: "meta" (JSON) + "file_0"..."file_N" (CAdES-BES DER).
//  2. Decode meta.requestId; look up SignRequestMeta from Redis via store.
//  3. For each file field: verify the CAdES-BES ECDSA signature.
//  4. Store a VerifyResult in Redis (success or failure).
//  5. Respond 200 OK — Diia retries on non-200.
//
// Security invariants:
//   - Never log file contents, signer identity in plaintext.
//   - Only SHA3-256 hashes appear in log entries.
//   - Return 500 for infrastructure failures (Redis down) so Diia retries.
//   - Return 200 for business failures (bad sig, unknown requestID) to halt retries.
func HandleSignCallback(store StoreInterface) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		start := time.Now()

		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxCallbackBody)

		// ── Parse multipart ────────────────────────────────────────────────
		mediaType, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil || !strings.HasPrefix(mediaType, "multipart/") {
			slog.Warn("diia callback: invalid content-type",
				slog.String("content_type", r.Header.Get("Content-Type")),
			)
			http.Error(w, "expected multipart/form-data", http.StatusBadRequest)
			return
		}
		mr := multipart.NewReader(r.Body, params["boundary"])

		var meta callbackMeta
		var cadesParts [][]byte // one DER blob per signed file

		for {
			part, err := mr.NextPart()
			if err == io.EOF {
				break
			}
			if err != nil {
				slog.Error("diia callback: multipart read error", slog.String("err", err.Error()))
				http.Error(w, "multipart read error", http.StatusBadRequest)
				return
			}

			fieldName := part.FormName()
			data, err := io.ReadAll(io.LimitReader(part, maxCallbackBody))
			part.Close()
			if err != nil {
				slog.Error("diia callback: part read error",
					slog.String("field", fieldName),
					slog.String("err", err.Error()),
				)
				http.Error(w, "part read error", http.StatusBadRequest)
				return
			}

			switch {
			case fieldName == "meta":
				if err := json.Unmarshal(data, &meta); err != nil {
					slog.Warn("diia callback: meta parse failed", slog.String("err", err.Error()))
					http.Error(w, "invalid meta JSON", http.StatusBadRequest)
					return
				}
			case strings.HasPrefix(fieldName, "file_"):
				cadesParts = append(cadesParts, data)
			default:
				slog.Debug("diia callback: unknown field", slog.String("field", fieldName))
			}
		}

		if meta.RequestID == "" {
			slog.Warn("diia callback: missing requestId in meta")
			http.Error(w, "missing requestId", http.StatusBadRequest)
			return
		}
		if len(cadesParts) == 0 {
			slog.Warn("diia callback: no signed files",
				slog.String("request_id", meta.RequestID),
			)
			http.Error(w, "no signed files", http.StatusBadRequest)
			return
		}

		// ── Redis lookup ───────────────────────────────────────────────────
		reqMeta, err := store.GetRequest(ctx, meta.RequestID)
		if err != nil {
			slog.Error("diia callback: GetRequest failed",
				slog.String("request_id", meta.RequestID),
				slog.String("err", err.Error()),
			)
			// Infrastructure failure — 500 triggers Diia retry.
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if reqMeta == nil {
			slog.Warn("diia callback: unknown requestId (expired or never seen)",
				slog.String("request_id", meta.RequestID),
			)
			// Unknown request — return 200 to halt Diia retries.
			w.WriteHeader(http.StatusOK)
			return
		}

		// ── Verify each CAdES-BES signature ───────────────────────────────
		allVerified := true
		var signerHash string
		var verifyErr string

		for i, cadesDER := range cadesParts {
			cert, err := verifyCAdESBES(cadesDER)
			if err != nil {
				allVerified = false
				verifyErr = fmt.Sprintf("file_%d: %s", i, err.Error())
				slog.Warn("diia callback: CAdES-BES verification failed",
					slog.String("request_id", meta.RequestID),
					slog.Int("file_index", i),
					slog.String("err", err.Error()),
				)
				break
			}
			// Hash the signer cert DER (SHA3-256) for safe logging and storage.
			h := sha3.New256()
			h.Write(cert.Raw)
			sh := hex.EncodeToString(h.Sum(nil))
			if signerHash == "" {
				signerHash = sh
			}
			slog.Info("diia callback: file signature verified",
				slog.String("request_id", meta.RequestID),
				slog.Int("file_index", i),
				slog.String("signer_hash", sh),
			)
		}

		// ── Persist result ─────────────────────────────────────────────────
		result := VerifyResult{
			RequestID:  meta.RequestID,
			Verified:   allVerified,
			SignerHash:  signerHash,
			FileKey:    meta.FileKey,
			VerifiedAt: time.Now().UTC(),
			ErrMsg:     verifyErr,
		}
		if err := store.SaveResult(ctx, result); err != nil {
			slog.Error("diia callback: SaveResult failed",
				slog.String("request_id", meta.RequestID),
				slog.String("err", err.Error()),
			)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		slog.Info("diia callback: processed",
			slog.String("request_id", meta.RequestID),
			slog.Bool("verified", allVerified),
			slog.Int("files", len(cadesParts)),
			slog.Duration("dur", time.Since(start)),
		)
		w.WriteHeader(http.StatusOK)
	}
}

// ── CAdES-BES ECDSA verification ─────────────────────────────────────────

// verifyCAdESBES parses and verifies a DER-encoded CAdES-BES (CMS SignedData)
// signature. Returns the signer's X.509 certificate on success.
//
// Verification steps (per RFC 5652 §5.6 and CAdES-BES):
//  1. DER-decode CMS ContentInfo.
//  2. Assert contentType == id-signedData.
//  3. DER-decode SignedData from Content.Bytes.
//  4. Extract the first SignerInfo.
//  5. Assert signatureAlgorithm == ecdsaWithSHA256.
//  6. Extract signer cert from SignedData.certificates[0].
//  7. Re-tag SignedAttrs IMPLICIT [0] (0xA0) → SET (0x31) per RFC 5652 §5.4.
//  8. SHA-256 over re-tagged bytes (protocol-mandated; see SHA-256 NOTE below).
//  9. DER-decode ECDSA {R, S} from SignerInfo.signature.
// 10. ecdsa.Verify against the cert's public key.
//
// SHA-256 NOTE: Step 8 intentionally uses SHA-256, not SHA3-256.
// CAdES-BES with ecdsaWithSHA256 (OID 1.2.840.10045.4.3.2) mandates SHA-256
// for the signed attributes digest. This is a protocol-mandated exception,
// identical in rationale to PKCE/RFC 7636. Internal identifiers (signer hash,
// Redis keys) always use SHA3-256.
func verifyCAdESBES(der []byte) (*x509.Certificate, error) {
	// ── Step 1–2: Parse ContentInfo, assert id-signedData ─────────────────
	var ci contentInfo
	rest, err := asn1.Unmarshal(der, &ci)
	if err != nil {
		return nil, fmt.Errorf("diia: parse ContentInfo: %w", err)
	}
	if len(rest) > 0 {
		return nil, errors.New("diia: trailing bytes after ContentInfo")
	}
	if !ci.ContentType.Equal(oidSignedData) {
		return nil, fmt.Errorf("diia: expected id-signedData OID, got %v", ci.ContentType)
	}

	// ── Step 3: Parse SignedData ───────────────────────────────────────────
	// Content.Bytes is the inner SignedData DER (EXPLICIT [0] wrapper stripped).
	var sd signedData
	if _, err := asn1.Unmarshal(ci.Content.Bytes, &sd); err != nil {
		return nil, fmt.Errorf("diia: parse SignedData: %w", err)
	}

	// ── Step 4: First SignerInfo ───────────────────────────────────────────
	if len(sd.SignerInfos) == 0 {
		return nil, errors.New("diia: no SignerInfo in SignedData")
	}
	si := sd.SignerInfos[0]

	// ── Step 5: Assert ecdsaWithSHA256 ─────────────────────────────────────
	if !si.SignatureAlgorithm.Algorithm.Equal(oidECDSAWithSHA256) {
		return nil, fmt.Errorf("diia: unsupported signatureAlgorithm %v (want ecdsaWithSHA256)",
			si.SignatureAlgorithm.Algorithm)
	}

	// ── Step 6: Signer certificate ────────────────────────────────────────
	// Certificates [0] IMPLICIT: .Bytes holds the content without the A0 wrapper.
	if len(sd.Certificates.Bytes) == 0 {
		return nil, errors.New("diia: no certificates in SignedData")
	}
	cert, err := parseCertFromCertSet(sd.Certificates.Bytes)
	if err != nil {
		return nil, fmt.Errorf("diia: parse signer cert: %w", err)
	}

	// ── Step 7: Re-tag signedAttrs 0xA0 → 0x31 ───────────────────────────
	if len(si.SignedAttrs.FullBytes) == 0 {
		return nil, errors.New("diia: empty signedAttrs")
	}
	if si.SignedAttrs.FullBytes[0] != 0xA0 {
		return nil, fmt.Errorf("diia: expected signedAttrs tag 0xA0, got 0x%02x",
			si.SignedAttrs.FullBytes[0])
	}
	toHash := make([]byte, len(si.SignedAttrs.FullBytes))
	copy(toHash, si.SignedAttrs.FullBytes)
	toHash[0] = 0x31 // UNIVERSAL SET (17)

	// ── Step 8: SHA-256 over re-tagged bytes ──────────────────────────────
	digest := sha256.Sum256(toHash) // protocol-mandated SHA-256, see doc

	// ── Step 9: Parse ECDSA {R, S} from signature OCTET STRING ───────────
	var sig ecdsaSigValue
	if _, err := asn1.Unmarshal(si.Signature, &sig); err != nil {
		return nil, fmt.Errorf("diia: parse ECDSA signature: %w", err)
	}
	if sig.R == nil || sig.S == nil {
		return nil, errors.New("diia: ECDSA signature missing R or S")
	}

	// ── Step 10: Verify ────────────────────────────────────────────────────
	pub, ok := cert.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return nil, errors.New("diia: signer cert does not contain an ECDSA public key")
	}
	if !ecdsa.Verify(pub, digest[:], sig.R, sig.S) {
		return nil, errors.New("diia: ECDSA signature verification failed")
	}

	return cert, nil
}

// parseCertFromCertSet parses the first X.509 certificate from the raw value
// bytes of the [0] IMPLICIT CertificateSet field (A0 tag already consumed).
// The bytes begin with a DER-encoded Certificate SEQUENCE.
func parseCertFromCertSet(b []byte) (*x509.Certificate, error) {
	var raw asn1.RawValue
	if _, err := asn1.Unmarshal(b, &raw); err != nil {
		return nil, fmt.Errorf("read first cert from set: %w", err)
	}
	return x509.ParseCertificate(raw.FullBytes)
}

// extractRNOKPP extracts the Ukrainian individual tax number (РНОКПП) from an
// X.509 certificate's Subject.SerialNumber field and returns it normalized as
// "UA:{number}". Returns an empty string if no serial number is present.
//
// Ukrainian QDCA certificates encode РНОКПП in the subject's serialNumber
// attribute (OID 2.5.4.5), sometimes with a "RNOKPP" prefix.
//
// Auth flow: hash = SHA3-256("UA:" + rnokpp) — never log the raw value.
func extractRNOKPP(cert *x509.Certificate) string {
	sn := cert.Subject.SerialNumber
	if sn == "" {
		return ""
	}
	sn = strings.TrimPrefix(sn, "RNOKPP")
	sn = strings.TrimPrefix(sn, "rnokpp")
	sn = strings.TrimSpace(sn)
	if sn == "" {
		return ""
	}
	return "UA:" + sn
}

// HashRNOKPP hashes a normalized RNOKPP ("UA:{number}") with SHA3-256 and
// returns the 64-char lowercase hex digest for use in audit logs and Redis keys.
// Always normalize via extractRNOKPP before calling.
func HashRNOKPP(normalizedRNOKPP string) string {
	h := sha3.New256()
	h.Write([]byte(normalizedRNOKPP))
	return hex.EncodeToString(h.Sum(nil))
}
