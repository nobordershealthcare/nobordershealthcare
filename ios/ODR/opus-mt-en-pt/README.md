# ODR Bundle: opus-mt-en-pt (English → Portuguese)

**On-Demand Resource tag:** `opus-mt-en-pt`
**Approximate bundle size:** ~85 MB
**Source model:** [Helsinki-NLP/opus-mt-en-pt](https://huggingface.co/Helsinki-NLP/opus-mt-en-pt)

## Expected files in this directory

After running the conversion script these files must be present:

| File | Description |
|------|-------------|
| `opus-mt-en-pt.mlpackage/` | CoreML model (MarianMT encoder+decoder) |
| `opus-mt-en-pt.spm` | SentencePiece vocabulary (source.spm from HuggingFace) |

## How to generate

```bash
# One-time setup
pip install -r scripts/requirements-coreml.txt

# Convert English → Portuguese
python scripts/convert-opus-mt-to-coreml.py --lang pt
```

The script writes all files directly into this directory.

## Xcode ODR configuration

In Xcode → target → Build Phases → Copy Bundle Resources, add each
`.mlpackage` and `.spm` file and set **On Demand Resource Tags** to:

```
opus-mt-en-pt
```

Initial install tag should be left **unset** — these are downloaded on first
use via `NSBundleResourceRequest`.

## Privacy

These files contain no patient data. They are generic language models
trained on public corpora (CC-aligned, OPUS dataset).
The model files may be bundled and distributed under the Apache 2.0 licence.
See: https://github.com/Helsinki-NLP/OPUS-MT-train/blob/master/LICENSE
