// sentencepiece_c_wrapper.h — C API bridge for the SentencePiece library.
//
// Swift cannot call C++ APIs directly. This header exposes a minimal C
// interface around SentencePieceProcessor so Swift (and the XCFramework
// module map) can consume it without touching C++ headers.
//
// Usage in Swift (once XCFramework is linked):
//   let handle = spm_load(vocabURL.path)
//   defer { spm_free(handle) }
//
//   var ids = [Int32](repeating: 0, count: 512)
//   var count: Int32 = 0
//   spm_encode(handle, "Hello", &ids, &count)
//
// Thread safety: spm_encode / spm_decode / spm_bos_id / spm_eos_id are
// safe to call from multiple threads on the SAME handle (SentencePiece
// processor is const after load). spm_load and spm_free are NOT thread-safe
// — call them from a single owning thread/actor (OpusMTEngine).

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

// Opaque handle returned by spm_load. Ownership belongs to the caller;
// must be released via spm_free when no longer needed.
typedef void* SPMHandle;

// ── Lifecycle ─────────────────────────────────────────────────────────────

/// Load a SentencePiece model from the file at `model_path`.
/// Returns NULL and writes a message to stderr on failure.
/// The returned handle must be freed with spm_free().
SPMHandle spm_load(const char* model_path);

/// Release all resources associated with `handle`.
/// Passing NULL is a no-op. After this call `handle` is invalid.
void spm_free(SPMHandle handle);

// ── Encoding ──────────────────────────────────────────────────────────────

/// Tokenise `text` into subword piece IDs.
///
/// @param handle     Handle returned by spm_load.
/// @param text       UTF-8 input string (null-terminated).
/// @param out_ids    Caller-allocated buffer to receive token IDs.
/// @param capacity   Number of int32_t slots available in out_ids.
/// @param out_count  On success, set to the number of IDs written.
/// @return 0 on success, non-zero on failure (e.g. handle NULL, overflow).
int spm_encode(
    SPMHandle        handle,
    const char*      text,
    int32_t*         out_ids,
    int32_t          capacity,
    int32_t*         out_count
);

// ── Decoding ──────────────────────────────────────────────────────────────

/// Decode a sequence of subword piece IDs back to a UTF-8 string.
///
/// @param handle     Handle returned by spm_load.
/// @param ids        Array of token IDs to decode.
/// @param count      Number of elements in `ids`.
/// @param out_buf    Caller-allocated buffer to receive the decoded string.
/// @param buf_size   Size of out_buf in bytes.
/// @return 0 on success, non-zero on failure.
int spm_decode(
    SPMHandle        handle,
    const int32_t*   ids,
    int32_t          count,
    char*            out_buf,
    int32_t          buf_size
);

// ── Special token IDs ─────────────────────────────────────────────────────

/// Returns the token ID for the beginning-of-sequence (BOS) token.
/// Returns -1 if the handle is NULL or the token is not in the vocabulary.
int32_t spm_bos_id(SPMHandle handle);

/// Returns the token ID for the end-of-sequence (EOS / </s>) token.
/// Returns -1 if the handle is NULL or the token is not in the vocabulary.
int32_t spm_eos_id(SPMHandle handle);

/// Returns the token ID for the padding token (<pad>).
/// Returns -1 if the handle is NULL or the token is not in the vocabulary.
int32_t spm_pad_id(SPMHandle handle);

/// Returns the vocabulary size of the loaded model.
/// Returns 0 if the handle is NULL.
int32_t spm_vocab_size(SPMHandle handle);

#ifdef __cplusplus
}  // extern "C"
#endif
