#!/usr/bin/env python3
"""
convert-opus-mt-to-coreml.py — Download Helsinki-NLP opus-mt models from
HuggingFace and convert them to CoreML .mlpackage format for use in the
noborders health wallet iOS app.

Usage:
    # Convert all pilot languages
    python scripts/convert-opus-mt-to-coreml.py --lang uk ru de pt

    # Convert a single language
    python scripts/convert-opus-mt-to-coreml.py --lang de

    # Specify custom output directory
    python scripts/convert-opus-mt-to-coreml.py --lang uk --out-dir ios/ODR

Requirements:
    pip install -r scripts/requirements-coreml.txt

Output per language (written to ios/ODR/opus-mt-en-{lang}/):
    opus-mt-en-{lang}.mlpackage/   — CoreML model (encoder+decoder bundled)
    opus-mt-en-{lang}.spm          — SentencePiece vocabulary file

CRITICAL: This script does NOT use the model for inference.
It only downloads weights and converts them to a static CoreML graph.
No patient data is involved at any stage of this script.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

# ── Dependency check ──────────────────────────────────────────────────────

def check_dependencies() -> None:
    missing = []
    for pkg in ["transformers", "coremltools", "torch", "sentencepiece"]:
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        print(f"[error] Missing packages: {', '.join(missing)}")
        print(f"        Run: pip install -r scripts/requirements-coreml.txt")
        sys.exit(1)

check_dependencies()

import numpy as np
import torch
import coremltools as ct
from transformers import MarianMTModel, MarianTokenizer

# ── Constants ─────────────────────────────────────────────────────────────

PILOT_LANGUAGES = ("uk", "ru", "de", "pt")
HF_MODEL_PREFIX = "Helsinki-NLP/opus-mt-en-"

# Constrain the encoder sequence length.
# Terminology labels from TerminologyMapper are always well under 64 tokens.
# Setting a static shape allows CoreML to optimise the graph more aggressively.
MAX_SRC_LEN = 64   # source tokens (English input)
MAX_TGT_LEN = 64   # target tokens (translated output, greedy decode cap)

# CoreML compute units: ALL includes ANE (Neural Engine) + GPU + CPU.
# cpuAndNeuralEngine is preferred for latency; set to cpuOnly if you hit
# numerical issues during conversion.
COMPUTE_UNITS = ct.ComputeUnit.ALL

# ── Vocabulary helper ─────────────────────────────────────────────────────

def copy_vocab(tokenizer: MarianTokenizer, lang: str, out_dir: Path) -> Path:
    """
    Copy the SentencePiece vocabulary file from the HuggingFace cache.

    MarianTokenizer always has a 'source.spm' (and sometimes 'target.spm').
    We copy source.spm — it is the file the on-device SentencePieceTokenizer
    must load to tokenise English input text.
    """
    spm_path = None

    for attr in ("spm_source", "vocab_file"):
        candidate = getattr(tokenizer, attr, None)
        if candidate and os.path.isfile(candidate):
            spm_path = Path(candidate)
            break

    if spm_path is None:
        # Fallback: save to a temp dir and pick the first .spm file found.
        with tempfile.TemporaryDirectory() as tmp:
            tokenizer.save_pretrained(tmp)
            candidates = list(Path(tmp).glob("*.spm"))
            if candidates:
                spm_path = candidates[0]

    if spm_path is None:
        print(f"  [vocab] WARNING: Could not locate .spm file for '{lang}'.")
        print(f"          Download it manually from:")
        print(f"          https://huggingface.co/{HF_MODEL_PREFIX}{lang}/blob/main/source.spm")
        return out_dir / f"opus-mt-en-{lang}.spm"

    dest = out_dir / f"opus-mt-en-{lang}.spm"
    shutil.copy2(spm_path, dest)
    print(f"  [vocab]   Saved: {dest} ({dest.stat().st_size // 1024} KB)")
    return dest


# ── Conversion logic ──────────────────────────────────────────────────────

def convert_language(lang: str, out_dir: Path) -> None:
    """
    Download a Helsinki-NLP/opus-mt-en-{lang} model and convert its encoder
    to a CoreML .mlpackage.

    Why encoder-only?
    The MarianMT decoder uses internal ops (new_ones, scatter_) that
    coremltools 8.x cannot lower to MIL.  The encoder is the expensive
    part (runs once per sentence) and converts cleanly.  The autoregressive
    decode loop runs on-device via ONNX Runtime or a server-side beam
    search until coremltools gains full decoder support.

    Tracing strategy:
    We trace model.model.encoder directly with return_dict=False so that
    the output is a plain tuple rather than a ModelOutput dataclass.  This
    avoids the new_ones op that the wrapper path triggers via
    BaseModelOutput.__init__.  A warmup forward pass with return_dict=False
    exercises the same branches, so the JIT tracer never sees new_ones.
    """
    import json

    model_id = f"{HF_MODEL_PREFIX}{lang}"
    lang_out_dir = out_dir / f"opus-mt-en-{lang}"
    lang_out_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n{'═' * 60}")
    print(f"  Language: en → {lang}")
    print(f"  Model:    {model_id}")
    print(f"  Output:   {lang_out_dir}")
    print(f"{'═' * 60}")

    # ── Download from HuggingFace ──────────────────────────────────────────
    print(f"  [download] Fetching tokenizer…")
    tokenizer = MarianTokenizer.from_pretrained(model_id)

    print(f"  [download] Fetching model weights (~300–400 MB)…")
    model = MarianMTModel.from_pretrained(model_id)
    model.eval()

    hidden_size: int = model.config.d_model
    enc_path = lang_out_dir / f"opus-mt-en-{lang}-encoder.mlpackage"

    # ── Trace the encoder ──────────────────────────────────────────────────
    # Use int32 (not int64/long) — coremltools 8.x maps int32 → MIL int32
    # cleanly; int64 often triggers unsupported cast ops on the ANE.
    dummy_ids  = torch.zeros(1, MAX_SRC_LEN, dtype=torch.int32)
    dummy_mask = torch.ones(1,  MAX_SRC_LEN, dtype=torch.int32)

    print(f"  [encoder] Warming up encoder (return_dict=False)…")
    with torch.no_grad():
        _ = model.model.encoder(
            input_ids=dummy_ids,
            attention_mask=dummy_mask,
            return_dict=False,
        )

    print(f"  [encoder] Tracing encoder…")
    with torch.no_grad():
        traced_encoder = torch.jit.trace(
            model.model.encoder,
            (dummy_ids, dummy_mask),
            strict=False,
        )

    # ── Convert encoder to CoreML ──────────────────────────────────────────
    print(f"  [encoder] Converting to CoreML (FLOAT16, iOS 16+)…")
    encoder_mlmodel = ct.convert(
        traced_encoder,
        inputs=[
            ct.TensorType(name="input_ids",     shape=(1, MAX_SRC_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, MAX_SRC_LEN), dtype=np.int32),
        ],
        outputs=[
            ct.TensorType(name="encoder_output"),
        ],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        compute_units=COMPUTE_UNITS,
    )
    encoder_mlmodel.save(str(enc_path))
    print(f"  [encoder] Saved: {enc_path}")

    # ── Decoder: skipped (not yet supported) ──────────────────────────────
    # The autoregressive decoder uses new_ones / scatter_ ops that
    # coremltools 8.x cannot lower.  Re-enable when support lands.
    print(f"  [decoder] Skipped — decoder conversion pending coremltools support.")

    # ── Vocabulary ────────────────────────────────────────────────────────
    copy_vocab(tokenizer, lang, lang_out_dir)

    # ── Write manifest ────────────────────────────────────────────────────
    manifest = lang_out_dir / "manifest.json"
    manifest.write_text(json.dumps({
        "model_id":          model_id,
        "src_lang":          "en",
        "tgt_lang":          lang,
        "encoder_seq_len":   MAX_SRC_LEN,
        "hidden_size":       hidden_size,
        "vocab_size":        model.config.vocab_size,
        "pad_token_id":      model.config.pad_token_id,
        "eos_token_id":      model.config.eos_token_id,
        "bos_token_id":      model.config.decoder_start_token_id,
        "encoder_model":     f"opus-mt-en-{lang}-encoder.mlpackage",
        "decoder_model":     None,   # not yet converted — see docstring above
        "vocab_file":        f"opus-mt-en-{lang}.spm",
        "coreml_min_ios":    "16.0",
        "compute_precision": "FLOAT16",
        "converted_by":      "scripts/convert-opus-mt-to-coreml.py",
    }, indent=2))
    print(f"  [manifest] Written: {manifest}")

    print(f"\n  ✔ en-{lang} encoder conversion complete.")


# ── Entry point ───────────────────────────────────────────────────────────

def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    default_out = repo_root / "ios" / "ODR"

    parser = argparse.ArgumentParser(
        description="Convert Helsinki-NLP opus-mt models to CoreML .mlpackage.",
    )
    parser.add_argument(
        "--lang",
        nargs="+",
        choices=list(PILOT_LANGUAGES),
        default=list(PILOT_LANGUAGES),
        metavar="LANG",
        help=f"Language codes to convert. Choices: {', '.join(PILOT_LANGUAGES)}. "
             f"Default: all pilot languages.",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=default_out,
        help=f"Root output directory (default: {default_out}). "
             f"Each language gets its own subdirectory.",
    )
    args = parser.parse_args()

    print("convert-opus-mt-to-coreml.py")
    print(f"  Languages : {', '.join(args.lang)}")
    print(f"  Output dir: {args.out_dir}")
    print(f"  Max src len: {MAX_SRC_LEN} tokens")
    print(f"  Max tgt len: {MAX_TGT_LEN} tokens")
    print()

    args.out_dir.mkdir(parents=True, exist_ok=True)

    failed: list[str] = []
    for lang in args.lang:
        try:
            convert_language(lang, args.out_dir)
        except Exception as exc:
            print(f"\n  ✖ en-{lang} FAILED: {exc}", file=sys.stderr)
            import traceback
            traceback.print_exc()
            failed.append(lang)

    print()
    if failed:
        print(f"Completed with errors. Failed languages: {', '.join(failed)}")
        sys.exit(1)
    else:
        print(f"All {len(args.lang)} language(s) converted successfully.")
        print()
        print("Next steps:")
        print("  1. Build the SentencePiece XCFramework (if not already built):")
        print("     ./scripts/build-sentencepiece-ios.sh")
        print()
        print("  2. Add encoder .mlpackage and .spm files to Xcode with ODR tags:")
        for lang in args.lang:
            print(f"     Tag 'opus-mt-en-{lang}' → ios/ODR/opus-mt-en-{lang}/")
        print()
        print("  3. Check manifest.json for BOS/EOS/PAD token IDs and pass them")
        print("     to xLMEngine.swift — the encoder-only CoreML model is loaded")
        print("     there; the decode loop runs separately (ONNX or server-side).")
        print()
        print("  NOTE: decoder_model is null in manifest.json — the Marian decoder")
        print("  uses new_ones/scatter_ ops not yet supported by coremltools 8.x.")


if __name__ == "__main__":
    main()
