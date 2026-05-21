// sentencepiece_c_wrapper.cpp — C implementation of the SPM bridge.
//
// Compiled as part of the sentencepiece-ios.xcframework by
// scripts/build-sentencepiece-ios.sh.
//
// Build requirements:
//   - SentencePiece source must be available at $SENTENCEPIECE_SRC
//   - Link against libsentencepiece.a (built from the same source)
//
// This file compiles as C++17 but exposes only C linkage symbols so Swift
// can consume them through the C module map.

#include "sentencepiece_c_wrapper.h"
#include "sentencepiece_processor.h"  // from google/sentencepiece

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

// ── Internal helpers ───────────────────────────────────────────────────────

static sentencepiece::SentencePieceProcessor* to_proc(SPMHandle h) {
    return static_cast<sentencepiece::SentencePieceProcessor*>(h);
}

// ── Lifecycle ─────────────────────────────────────────────────────────────

SPMHandle spm_load(const char* model_path) {
    if (!model_path) {
        std::fprintf(stderr, "[spm] spm_load: model_path is NULL\n");
        return nullptr;
    }
    auto* proc = new sentencepiece::SentencePieceProcessor();
    const auto status = proc->Load(model_path);
    if (!status.ok()) {
        std::fprintf(stderr, "[spm] spm_load: failed to load '%s': %s\n",
                     model_path, status.ToString().c_str());
        delete proc;
        return nullptr;
    }
    return static_cast<SPMHandle>(proc);
}

void spm_free(SPMHandle handle) {
    if (!handle) return;
    delete to_proc(handle);
}

// ── Encoding ──────────────────────────────────────────────────────────────

int spm_encode(
    SPMHandle   handle,
    const char* text,
    int32_t*    out_ids,
    int32_t     capacity,
    int32_t*    out_count)
{
    if (!handle || !text || !out_ids || !out_count) return -1;
    *out_count = 0;

    std::vector<int> ids;
    const auto status = to_proc(handle)->Encode(text, &ids);
    if (!status.ok()) {
        std::fprintf(stderr, "[spm] spm_encode: %s\n", status.ToString().c_str());
        return -2;
    }

    const int32_t n = static_cast<int32_t>(ids.size());
    if (n > capacity) {
        std::fprintf(stderr, "[spm] spm_encode: output overflow (%d > %d)\n",
                     n, capacity);
        return -3;
    }

    for (int32_t i = 0; i < n; ++i) {
        out_ids[i] = static_cast<int32_t>(ids[i]);
    }
    *out_count = n;
    return 0;
}

// ── Decoding ──────────────────────────────────────────────────────────────

int spm_decode(
    SPMHandle      handle,
    const int32_t* ids,
    int32_t        count,
    char*          out_buf,
    int32_t        buf_size)
{
    if (!handle || !ids || !out_buf || buf_size <= 0) return -1;
    out_buf[0] = '\0';

    std::vector<int> id_vec(ids, ids + count);
    std::string decoded;
    const auto status = to_proc(handle)->Decode(id_vec, &decoded);
    if (!status.ok()) {
        std::fprintf(stderr, "[spm] spm_decode: %s\n", status.ToString().c_str());
        return -2;
    }

    const auto src_len = static_cast<int32_t>(decoded.size());
    if (src_len >= buf_size) {
        std::fprintf(stderr, "[spm] spm_decode: buffer too small (%d bytes for %d chars)\n",
                     buf_size, src_len);
        return -3;
    }

    std::memcpy(out_buf, decoded.c_str(), src_len + 1 /* include NUL */);
    return 0;
}

// ── Special token IDs ─────────────────────────────────────────────────────

int32_t spm_bos_id(SPMHandle handle) {
    if (!handle) return -1;
    return static_cast<int32_t>(to_proc(handle)->bos_id());
}

int32_t spm_eos_id(SPMHandle handle) {
    if (!handle) return -1;
    return static_cast<int32_t>(to_proc(handle)->eos_id());
}

int32_t spm_pad_id(SPMHandle handle) {
    if (!handle) return -1;
    return static_cast<int32_t>(to_proc(handle)->pad_id());
}

int32_t spm_vocab_size(SPMHandle handle) {
    if (!handle) return 0;
    return static_cast<int32_t>(to_proc(handle)->GetPieceSize());
}
