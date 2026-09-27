"""Compare Models/*.mlpackage against the PyTorch port (fp32).

The predictor is checked on every painting in Styles/, the transformers on one content image.
Usage: uv run verify_coreml.py [--content PATH] [--style PATH]
"""
import argparse
import glob
import json
import os

import coremltools as ct
import numpy as np
import torch
from PIL import Image

from convert_coreml import MODELS, PADDING_KEY, predictor_input_size
from tfjs_weights import load_predictor, load_transformer

STYLES = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Styles"))
UNITS = {"GPU": ct.ComputeUnit.CPU_AND_GPU, "ANE": ct.ComputeUnit.CPU_AND_NE}


def to_tensor(img):
    return torch.from_numpy(np.asarray(img, dtype=np.float32) / 255.0).permute(2, 0, 1)[None]


def predictor_image(path):
    img = Image.open(path).convert("RGB")
    return img.resize(predictor_input_size(*img.size), Image.BILINEAR)


def image_diff(got, ref01):
    got = np.asarray(got.convert("RGB"), dtype=np.float64) / 255.0
    ref = ref01.astype(np.float64)
    psnr = 10 * np.log10(1.0 / np.mean((got - ref) ** 2))
    return psnr, int(np.abs(got * 255 - np.round(ref * 255)).max())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--content", default=os.path.join(STYLES, "hay_wain.jpg"))
    ap.add_argument("--style", default=os.path.join(STYLES, "starry_night.jpg"))
    args = ap.parse_args()
    torch.set_grad_enabled(False)

    # All PyTorch work happens before any Core ML prediction; interleaving them crashed torch once.
    pred = load_predictor()
    catalog = json.load(open(os.path.join(STYLES, "catalog.json")))
    style_images = {s["id"]: predictor_image(os.path.join(STYLES, s["file"])) for s in catalog}
    torch_bottlenecks = {k: pred(to_tensor(img)).numpy().reshape(-1) for k, img in style_images.items()}
    style = pred(to_tensor(predictor_image(args.style)))

    transformers = []
    for path in sorted(glob.glob(os.path.join(MODELS, "MagentaTransformer_*.mlpackage"))):
        meta = ct.models.MLModel(path, skip_model_load=True)
        spec = meta.get_spec().description.input[0].type.imageType
        w, h = spec.width, spec.height
        padding = meta.user_defined_metadata[PADDING_KEY]
        content = Image.open(args.content).convert("RGB").resize((w, h), Image.BILINEAR)
        ref = load_transformer(padding)(to_tensor(content), style)[0].permute(1, 2, 0).numpy()[:h, :w]
        transformers.append((path, f"{w}x{h}", padding, content, ref))
    transformers.sort(key=lambda t: t[3].size[0])

    print("predictor vs PyTorch, %d styles" % len(style_images))
    for unit, cu in UNITS.items():
        ml = ct.models.MLModel(os.path.join(MODELS, "MagentaPredictor.mlpackage"), compute_units=cu)
        worst_abs, worst_cos = 0.0, 1.0
        for k, img in style_images.items():
            got = ml.predict({"style_image": img})["bottleneck"].reshape(-1)
            want = torch_bottlenecks[k]
            worst_abs = max(worst_abs, float(np.abs(got - want).max()))
            worst_cos = min(worst_cos, float(got @ want / np.linalg.norm(got) / np.linalg.norm(want)))
        print(f"  {unit}: max abs {worst_abs:.4f}, min cosine {worst_cos:.5f}")

    print("transformer vs PyTorch (PSNR dB, max diff /255)")
    for path, size, padding, content, ref in transformers:
        row = []
        for unit, cu in UNITS.items():
            got = ct.models.MLModel(path, compute_units=cu).predict({"content": content, "style": style.numpy()})["stylized"]
            psnr, max_diff = image_diff(got, ref)
            row.append(f"{unit} {psnr:.2f} dB, {max_diff}")
        print(f"  {size} ({padding}): " + " | ".join(row))


if __name__ == "__main__":
    main()
