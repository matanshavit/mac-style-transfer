# Model tools

Converts the Magenta arbitrary style network (the TF.js checkpoints behind `@magenta/image` 0.2.1) to the Core ML models in `Models/`.

## Setup

Needs [uv](https://docs.astral.sh/uv/).

```sh
cd Tools/python
uv sync
```

## Regenerate Models/

```sh
uv run fetch_magenta.py    # checkpoints into cache/ (gitignored), sha256 pinned
uv run convert_coreml.py   # MagentaPredictor + MagentaTransformer_{480x270,640x360,960x540,1280x720}
uv run verify_coreml.py    # Core ML vs PyTorch
```

`convert_coreml.py --sizes 640x360 --padding zeros` builds other sizes, or the original zero padding. Zero padding matches `@magenta/image` exactly but leaves a dark border. The default is replicate.

The predictor only accepts height 256 and a width that is a multiple of 32 in 128..512. Resize the painting to height 256 keeping its aspect ratio, then round the width to the nearest allowed value.

## Measured

M5 Pro, macOS 26.6. Median of 300 synchronous predictions from Swift with IOSurface-backed buffers. PSNR is against the PyTorch port in fp32 (`verify_coreml.py`).

| Size | GPU ms | ANE ms | PSNR GPU / ANE |
|---|---|---|---|
| 480x270 | 3.97 | 4.00 | 58.70 / 54.14 dB |
| 640x360 | 6.45 | 6.83 | 58.70 / 54.17 dB |
| 960x540 | 14.47 | 15.31 | 58.68 / 54.22 dB |
| 1280x720 | 25.48 | 26.76 | 58.70 / 54.14 dB |

Predictor: about 1 ms on the ANE. Its bottleneck is within 0.0055 of PyTorch (cosine 0.99997 or higher) on all 15 paintings in `Styles/`.

## Checking the port against TensorFlow

```sh
uv run --no-project --python 3.12 --with tensorflow --with torch==2.7.1 --with pillow optional/tf_reference.py
```

This runs the original graphs in TensorFlow next to the PyTorch port with zero padding. Measured max abs diff: 1.8e-6 on the bottleneck, 1.4e-5 on the stylized image.
