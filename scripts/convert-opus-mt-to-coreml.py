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

# ── Conversion logic ──────────────────────────────────────────────────────

class MarianEncoderWrapper(torch.nn.Module):
    """
    Wraps the MarianMT encoder so coremltools can trace it.

    Inputs:
        input_ids      — Int64 [1, src_len]
        attention_mask — Int64 [1, src_len]
    Output:
        last_hidden_state — Float32 [1, src_len, hidden_size]
    """
    def __init__(self, model: MarianMTModel) -> None:
        super().__init__()
        self.encoder = model.get_encoder()

    def forward(
        self,
        input_ids: torch.Tensor,
        attention_mask: torch.Tensor,
    ) -> torch.Tensor:
        out = self.encoder(input_ids=input_ids, attention_mask=attention_mask)
        return out.last_hidden_state


class MarianDecoderStepWrapper(torch.nn.Module):
    """
    Wraps a single autoregressive decoding step of the MarianMT decoder.

    This exports ONE decoder step (next token logits given encoder output
    and the token generated so far). The Swift inference loop calls this
    repeatedly until EOS or max_len is reached.

    Inputs:
        decoder_input_ids — Int64  [1, 1]           (last predicted token)
        encoder_hidden    — Float32 [1, src_len, hidden]
        encoder_mask      — Int64  [1, src_len]
    Output:
        logits            — Float32 [1, 1, vocab_size]
    """
    def __init__(self, model: MarianMTModel) -> None:
        super().__init__()
        self.model = model

    def forward(
        self,
        decoder_input_ids: torch.Tensor,
        encoder_hidden: torch.Tensor,
        encoder_mask: torch.Tensor,
    ) -> torch.Tensor:
        out = self.model(
            input_ids=None,
            attention_mask=encoder_mask,
            decoder_input_ids=decoder_input_ids,
            encoder_outputs=(encoder_hidden,),
            return_dict=False,
        )
        # out[0]: logits [1, 1, vocab_size]
        return out[0]


def convert_encoder(
    model: MarianMTModel,
    lang: str,
    out_dir: Path,
) -> Path:
    """Convert the MarianMT encoder to a CoreML .mlpackage."""
    print(f"  [encoder] Tracing encoder for '{lang}'…")
    wrapper = MarianEncoderWrapper(model).eval()

    # Example inputs for tracing (values are arbitrary — only shapes matter).
    dummy_ids  = torch.zeros(1, MAX_SRC_LEN, dtype=torch.long)
    dummy_mask = torch.ones(1, MAX_SRC_LEN, dtype=torch.long)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_ids, dummy_mask))

    print(f"  [encoder] Converting to CoreML…")
    cml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="input_ids",      shape=(1, MAX_SRC_LEN), dtype=int),
            ct.TensorType(name="attention_mask",  shape=(1, MAX_SRC_LEN), dtype=int),
        ],
        outputs=[
            ct.TensorType(name="encoder_hidden_states"),
        ],
        compute_units=COMPUTE_UNITS,
        minimum_deployment_target=ct.target.iOS16,
    )

    pkg_path = out_dir / f"opus-mt-en-{lang}-encoder.mlpackage"
    cml_model.save(str(pkg_path))
    print(f"  [encoder] Saved: {pkg_path}")
    return pkg_path


def convert_decoder_step(
    model: MarianMTModel,
    lang: str,
    out_dir: Path,
    hidden_size: int,
) -> Path:
    """Convert a single MarianMT decoder step to a CoreML .mlpackage."""
    print(f"  [decoder] Tracing single-step decoder for '{lang}'…")
    wrapper = MarianDecoderStepWrapper(model).eval()

    dummy_dec_ids = torch.zeros(1, 1, dtype=torch.long)
    dummy_enc     = torch.zeros(1, MAX_SRC_LEN, hidden_size)
    dummy_enc_mask = torch.ones(1, MAX_SRC_LEN, dtype=torch.long)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_dec_ids, dummy_enc, dummy_enc_mask))

    print(f"  [decoder] Converting to CoreML…")
    cml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="decoder_input_ids", shape=(1, 1),                           dtype=int),
            ct.TensorType(name="encoder_hidden",    shape=(1, MAX_SRC_LEN, hidden_size),    dtype=float),
            ct.TensorType(name="encoder_mask",      shape=(1, MAX_SRC_LEN),                 dtype=int),
        ],
        outputs=[
            ct.TensorType(name="logits"),
        ],
        compute_units=COMPUTE_UNITS,
        minimum_deployment_target=ct.target.iOS16,
    )

    pkg_path = out_dir / f"opus-mt-en-{lang}-decoder.mlpackage"
    cml_model.save(str(pkg_path))
    print(f"  [decoder] Saved: {pkg_path}")
    return pkg_path


def copy_vocab(tokenizer: MarianTokenizer, lang: str, out_dir: Path) -> Path:
    """
    Copy the SentencePiece vocabulary file from the HuggingFace cache.

    MarianTokenizer always has a 'source.spm' (and sometimes 'target.spm').
    We copy source.spm — it is the file the on-device SentencePieceTokenizer
    must load to tokenise English input text.
    """
    # HuggingFace caches the tokenizer files in the same directory as the
    # model config. vocab_files_names maps logical names to actual filenames.
    spm_path = None

    for attr in ("spm_source", "vocab_file"):
        candidate = getattr(tokenizer, attr, None)
        if candidate and os.path.isfile(candidate):
            spm_path = Path(candidate)
            break

    if spm_path is None:
        # Fallback: walk the tokenizer's save directory.
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


def convert_language(lang: str, out_dir: Path) -> None:
    """Download and convert a single language pair."""
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
    model = MarianMTModel.from_pretrained(model_id, torchscript=True)
    model.eval()

    hidden_size: int = model.config.d_model

    # ── Convert ───────────────────────────────────────────────────────────
    convert_encoder(model, lang, lang_out_dir)
    convert_decoder_step(model, lang, lang_out_dir, hidden_size)
    copy_vocab(tokenizer, lang, lang_out_dir)

    # ── Write manifest ────────────────────────────────────────────────────
    manifest = lang_out_dir / "manifest.json"
    import json
    manifest.write_text(json.dumps({
        "model_id":     model_id,
        "lang_pair":    f"en-{lang}",
        "max_src_len":  MAX_SRC_LEN,
        "max_tgt_len":  MAX_TGT_LEN,
        "hidden_size":  hidden_size,
        "vocab_size":   model.config.vocab_size,
        "pad_token_id": model.config.pad_token_id,
        "eos_token_id": model.config.eos_token_id,
        "bos_token_id": model.config.decoder_start_token_id,
        "encoder_model": f"opus-mt-en-{lang}-encoder.mlpackage",
        "decoder_model": f"opus-mt-en-{lang}-decoder.mlpackage",
        "vocab_file":    f"opus-mt-en-{lang}.spm",
        "coreml_min_ios": "16.0",
        "converted_by":  "scripts/convert-opus-mt-to-coreml.py",
    }, indent=2))
    print(f"  [manifest] Written: {manifest}")

    print(f"\n  ✔ en-{lang} conversion complete.")


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
        print("  1. Build the SentencePiece XCFramework:")
        print("     ./scripts/build-sentencepiece-ios.sh")
        print()
        print("  2. Add .mlpackage and .spm files to Xcode with ODR tags:")
        for lang in args.lang:
            print(f"     Tag 'opus-mt-en-{lang}' → ios/ODR/opus-mt-en-{lang}/")
        print()
        print("  3. Update the BOS/EOS token IDs in xLMEngine.swift if they")
        print("     differ from the Helsinki-NLP defaults (check manifest.json).")


if __name__ == "__main__":
    main()
