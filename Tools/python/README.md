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
uv run convert_coreml.py --checkpoint CKPT.pt   # StableTransformer_*, see Temporal stability
uv run verify_coreml.py --checkpoint CKPT.pt    # Core ML vs PyTorch; without --checkpoint it skips StableTransformer_*
```

`convert_coreml.py --sizes 640x360 --padding zeros` builds other sizes, or the original zero padding. Zero padding matches `@magenta/image` exactly but leaves a dark border. The default is replicate.

The predictor only accepts height 256 and a width that is a multiple of 32 in 128..512. Resize the painting to height 256 keeping its aspect ratio, then round the width to the nearest allowed value.

## Measured

M5 Pro, macOS 26.6, nothing else running. Median of 300 synchronous predictions from Swift with IOSurface-backed buffers (`stylecam-cli bench`). PSNR is against the PyTorch port in fp32 (`verify_coreml.py`).

| Model | GPU ms | ANE ms | PSNR GPU / ANE |
|---|---|---|---|
| MagentaTransformer 480x270 | 3.46 | 3.90 | 58.70 / 54.14 dB |
| MagentaTransformer 640x360 | 5.69 | 6.69 | 58.70 / 54.17 dB |
| MagentaTransformer 960x540 | 12.53 | 15.02 | 58.68 / 54.22 dB |
| MagentaTransformer 1280x720 | 22.32 | 26.35 | 58.70 / 54.14 dB |
| StableTransformer 480x270 | 3.64 | 4.61 | 58.77 / 54.25 dB |
| StableTransformer 640x360 | 5.96 | 7.86 | 58.76 / 54.21 dB |
| StableTransformer 960x540 | 13.38 | 17.86 | 58.75 / 54.22 dB |
| StableTransformer 1280x720 | 24.09 | 31.32 | 58.76 / 54.23 dB |

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
uv run train_stable.py --data DATA --out CKPT
uv run stability_metrics.py magenta-replicate CKPT/antialias.pt --data DATA
uv run convert_coreml.py --checkpoint CKPT/antialias.pt --sizes 960x540 --out OUT
```

`DATA` holds COCO `val2017/`, a person-heavy subset of it in `content500/`, `heldout/`, and `video/` with the 720p60 clips `Johnny_1280x720_60.y4m` and `KristenAndSara_1280x720_60.y4m` (I420 y4m, read as limited range unless the header says `XCOLORRANGE=FULL`). The metrics use 50 held-out images and 3 paintings that training skips, and 100 frames of each clip at 960x540 and 30 fps. Moving pixels come from RAFT-small flow; torchvision downloads its weights on first use. `--arch antialias`, the default, blurs before the two stride-2 convs and upsamples bilinearly; the Magenta weights load into it unchanged. `convert_coreml.py --checkpoint` keeps the model inputs and outputs and names the models `StableTransformer_*`.

The teacher's fine texture moves with the stride-4 grid, not with the image, so a shift-stable student cannot match it pixel for pixel. A per-pixel or full-resolution VGG loss then pays the student to blur and lose contrast, and matching the energy of that texture makes the student add texture that flickers. `train_stable.py` distills to the teacher averaged over 4 grid positions, and compares low-passed pixels, pooled early VGG features, Gram matrices, and per-image band energy.

Shipped models (replicate padding), 0-255 scale:

| Metric | Classic | Steady |
|---|---|---|
| Output diff after a 1 / 2 / 3 / 4 / 8 px shift, motion compensated | 10.9 / 13.9 / 10.9 / 0.9 / 1.3 | 2.7 / 3.2 / 2.8 / 0.7 / 1.0 |
| Re-roll: mean distance to the output averaged over the 16 shifts of 0-3 px | 9.4 | 2.4 |
| Top-octave luma energy, output / shift-averaged | 21.4 / 11.1 | 10.8 / 9.5 |
| Output / input change, gaussian noise 2/255: COCO per pixel, smooth; static wall | 2.2, 6.0; 8.4 Johnny, 6.7 KristenAndSara | 0.9, 2.9; 3.4 Johnny, 2.6 KristenAndSara |
| Flow-warped luma error on moving pixels, output (input) | 14.1 (2.4) Johnny, 14.9 (2.5) KristenAndSara | 8.7 Johnny, 9.3 KristenAndSara |
| Frame-to-frame luma change on the static background, output (input) | 14.8 (0.82) Johnny, 11.8 (0.78) KristenAndSara | 6.8 Johnny, 5.2 KristenAndSara |

The shipped `StableTransformer_*` models come from `train_stable.py` with its defaults and `--steps 1500` (seed 0, 13 minutes). A 30k-step run with the same defaults is steadier (2 px shift error 1.7-2.5 against 3.2), but all 10 checkpoints measured, from step 2000 to 30000, move layout and tone further from classic (low-pass distance 9.7-13.9 against 8.3). The pick is the lowest 2 px shift error and static flicker with, relative to classic, low-pass distance at most 8.5, mid band and luma std ratios at least 0.95, and Gram to painting at most 0.86.

A 10k-step run with the learning rate decayed to the end (`cache/checkpoints/stable10k.pt`, not in git) passes those gates and is a little crisper (2 px shift 2.1). In the app, though, its static flicker was 14% higher on Johnny and 5% lower on KristenAndSara, so it did not replace the 1500-step model.

Half of the classic model's top-octave texture is the re-roll itself. The flow-warped error rises with texture energy even when the texture moves correctly, because flow error scales with it.

Most of the shift error comes from the nearest upsampling, but bilinear upsampling also removes stable texture. With the Magenta weights on 16 held-out images, the 2 px error is 13.8 with nearest, 13.8 with the blur alone, 7.4 with bilinear alone, and 6.1 with both, and the shift-averaged top-octave energy is 11.0, 9.8, 6.9 and 6.8. At 960x540 the anti-aliased graph takes 13.4 ms on the GPU (classic: 12.5) and 17.9 ms on the ANE (classic: 15.0); at 640x360 on the ANE it takes 7.9 ms (classic: 6.7). Median of 300 synchronous predictions on an idle Mac. Bilinear upsampling is about 2.1 ms of the ANE cost at 960x540 and free on the GPU. The blur costs about 0.7 ms on both.
