# ODR Bundle: opus-mt-en-uk (English → Ukrainian)

**On-Demand Resource tag:** `opus-mt-en-uk`
**Approximate bundle size:** ~85 MB
**Source model:** [Helsinki-NLP/opus-mt-en-uk](https://huggingface.co/Helsinki-NLP/opus-mt-en-uk)

## Expected files in this directory

After running the conversion script these files must be present:

| File | Description |
|------|-------------|
| `opus-mt-en-uk-encoder.mlpackage/` | CoreML encoder (MarianMT) |
| `opus-mt-en-uk-decoder.mlpackage/` | CoreML single-step decoder |
| `opus-mt-en-uk.spm` | SentencePiece vocabulary (source.spm from HuggingFace) |

> **Note:** The current xLMEngine.swift uses a combined single-model interface
> (`opus-mt-en-uk.mlpackage` with `input_ids → output_ids`). If you use the
> split encoder+decoder export, update `runInference()` accordingly.
> The conversion script produces the single-model format by default.

## How to generate

```bash
# One-time setup
pip install -r scripts/requirements-coreml.txt

# Convert English → Ukrainian
python scripts/convert-opus-mt-to-coreml.py --lang uk
```

The script writes all files directly into this directory.

## Xcode ODR configuration

In Xcode → target → Build Phases → Copy Bundle Resources, add each
`.mlpackage` and `.spm` file and set **On Demand Resource Tags** to:

```
opus-mt-en-uk
```

Initial install tag should be left **unset** — these are downloaded on first
use via `NSBundleResourceRequest`.

## Privacy

These files contain no patient data. They are generic language models
trained on public corpora (CC-aligned, OPUS dataset).
The model files may be bundled and distributed under the Apache 2.0 licence.
See: https://github.com/Helsinki-NLP/OPUS-MT-train/blob/master/LICENSE
