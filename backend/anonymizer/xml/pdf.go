package xml

import (
	"encoding/hex"
	"fmt"
	"time"

	"golang.org/x/crypto/sha3"
)

// PDFMeta carries the metadata embedded in a DRM-watermarked PDF.
type PDFMeta struct {
	// Watermark is SHA3-256(requesterHash + timestamp) — never the raw requester ID.
	Watermark string
	Content   []byte // XML or structured content to embed
}

// BuildPDFMeta assembles the PDF metadata for a DRM health record PDF.
// The watermark binds the requester identity (as a hash) to the generation
// timestamp so the document can be traced if leaked, without exposing PII.
//
// requesterHash: SHA3-256(per-user-salt + userID) — the project standard hash,
// already computed upstream. Never the raw user identifier.
func BuildPDFMeta(requesterHash string, content []byte) (PDFMeta, error) {
	if len(requesterHash) != 64 {
		return PDFMeta{}, fmt.Errorf("requesterHash must be 64 hex chars")
	}

	ts := time.Now().UTC().Format(time.RFC3339Nano)
	h := sha3.Sum256([]byte(requesterHash + ts))
	watermark := hex.EncodeToString(h[:])

	return PDFMeta{
		Watermark: watermark,
		Content:   content,
	}, nil
}

// RenderPDF is a stub. The actual PDF rendering library (e.g. unipdf or
// a wkhtmltopdf sidecar) is wired here. The watermark string is embedded
// in the PDF metadata and as a visible footer on each page.
// Plaintext content is zeroed from memory after rendering.
func RenderPDF(meta PDFMeta) ([]byte, error) {
	// TODO: integrate PDF rendering library.
	// Requirements:
	//   - Embed meta.Watermark in PDF /Info dictionary and as page footer.
	//   - Apply DRM: print-only, no copy, no text selection.
	//   - Zero meta.Content after the PDF bytes are assembled.
	//   - Return PDF bytes to caller; never write to disk.
	return nil, fmt.Errorf("pdf rendering not yet implemented")
}
