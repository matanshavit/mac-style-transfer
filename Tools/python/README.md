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

## Temporal stability

Moving the input by 1 to 3 px re-rolls the brush texture, and camera noise re-rolls it on flat areas like a wall. `stability_metrics.py` measures this and `train_stable.py` fine-tunes against it.

```sh
uv run stability_metrics.py magenta-replicate magenta-aa --data DATA --stills STILLS
uv run train_stable.py --arch antialias --data DATA --out CKPT
uv run stability_metrics.py magenta-replicate CKPT/antialias.pt --data DATA
uv run convert_coreml.py --checkpoint CKPT/antialias.pt --sizes 960x540 --out OUT
```

`DATA` holds COCO `val2017/`, a person-heavy subset of it in `content500/`, `heldout/`, and `video/` with the 720p60 clips `Johnny_1280x720_60.y4m` and `KristenAndSara_1280x720_60.y4m` (I420 y4m, read as limited range unless the header says `XCOLORRANGE=FULL`). The metrics use 50 held-out images that training skips, 3 paintings, and 100 frames of each clip at 960x540 and 30 fps. Moving pixels come from RAFT-small flow; torchvision downloads its weights on first use. `--arch antialias`, the default, blurs before the two stride-2 convs and upsamples bilinearly; the Magenta weights load into it unchanged. `convert_coreml.py --checkpoint` keeps the model inputs and outputs, and without `--out` it overwrites the shipped transformers.

Shipped model (replicate padding), 0-255 scale:

| Metric | Value |
|---|---|
| Output diff after a 1 / 2 / 3 / 4 / 8 px shift, motion compensated | 10.9 / 13.9 / 10.9 / 0.9 / 1.3 |
| Re-roll: mean distance to the output averaged over the 16 shifts of 0-3 px | 9.4 |
| Top-octave luma energy, output / shift-averaged | 21.4 / 11.1 |
| Output / input change, gaussian noise 2/255: COCO per pixel, smooth; static wall | 2.2, 6.0; 8.4 Johnny, 6.7 KristenAndSara |
| Flow-warped luma error on moving pixels, output (input) | 14.1 (2.4) Johnny, 14.9 (2.5) KristenAndSara |
| Frame-to-frame luma change on the static background, output (input) | 14.8 (0.82) Johnny, 11.8 (0.78) KristenAndSara |

Half of the shipped model's top-octave texture is the re-roll itself. The flow-warped error rises with texture energy even when the texture moves correctly, because flow error scales with it.

Most of the shift error comes from the nearest upsampling, but bilinear upsampling also removes stable texture. With the Magenta weights on 16 held-out images, the 2 px error is 13.8 with nearest, 13.8 with the blur alone, 7.4 with bilinear alone, and 6.1 with both, and the shift-averaged top-octave energy is 11.0, 9.8, 6.9 and 6.8. At 960x540 the anti-aliased graph takes 14.9 ms on the GPU (shipped: 14.0) and 17.9 ms on the ANE (shipped: 15.0); at 640x360 on the ANE it takes 7.9 ms (shipped: 6.7). Median of 300 synchronous predictions. Bilinear upsampling is about 2.1 ms of the ANE cost at 960x540 and free on the GPU. The blur costs about 0.7 ms on both.
