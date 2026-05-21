# ODR Bundle: opus-mt-en-de (English → German)

**On-Demand Resource tag:** `opus-mt-en-de`
**Approximate bundle size:** ~85 MB
**Source model:** [Helsinki-NLP/opus-mt-en-de](https://huggingface.co/Helsinki-NLP/opus-mt-en-de)

## Expected files in this directory

After running the conversion script these files must be present:

| File | Description |
|------|-------------|
| `opus-mt-en-de.mlpackage/` | CoreML model (MarianMT encoder+decoder) |
| `opus-mt-en-de.spm` | SentencePiece vocabulary (source.spm from HuggingFace) |

## How to generate

```bash
# One-time setup
pip install -r scripts/requirements-coreml.txt

# Convert English → German
python scripts/convert-opus-mt-to-coreml.py --lang de
```

The script writes all files directly into this directory.

## Xcode ODR configuration

In Xcode → target → Build Phases → Copy Bundle Resources, add each
`.mlpackage` and `.spm` file and set **On Demand Resource Tags** to:

```
opus-mt-en-de
```

Initial install tag should be left **unset** — these are downloaded on first
use via `NSBundleResourceRequest`.

## Privacy

These files contain no patient data. They are generic language models
trained on public corpora (CC-aligned, OPUS dataset).
The model files may be bundled and distributed under the Apache 2.0 licence.
See: https://github.com/Helsinki-NLP/OPUS-MT-train/blob/master/LICENSE
