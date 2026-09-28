"""Convert the PyTorch port to Core ML and write Models/*.mlpackage.

Usage: uv run convert_coreml.py [--sizes 480x270 640x360 ...] [--padding replicate|zeros|reflect]
       uv run convert_coreml.py --checkpoint ckpt.pt [--sizes ...] [--name StableTransformer] [--out DIR]

--checkpoint converts a train_stable.py transformer (either architecture) with the same inputs and
outputs, and skips the predictor, which fine-tuning does not change.
"""
import argparse
import os
import shutil
import warnings

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn

from magenta_torch import BOTTLENECK_DIM, load_checkpoint
from tfjs_weights import load_predictor, load_transformer

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS = os.path.normpath(os.path.join(HERE, "..", "..", "Models"))
DEFAULT_SIZES = ["480x270", "640x360", "960x540", "1280x720"]
PREDICTOR_HEIGHT = 256
PREDICTOR_WIDTHS = list(range(128, 513, 32))
PREDICTOR_RULE = ("resize to height 256 keeping the aspect ratio, then round the width to the "
                  "nearest multiple of 32 and clamp it to 128..512")
PADDING_KEY = "stylecam.padding"
ANTIALIAS_KEY = "stylecam.antialias"


def predictor_input_size(width, height):
    w = round(PREDICTOR_HEIGHT * width / height / 32) * 32
    return min(max(w, PREDICTOR_WIDTHS[0]), PREDICTOR_WIDTHS[-1]), PREDICTOR_HEIGHT


def fold_input_scale(conv):
    """Let a conv that expects [0, 1] take 0..255. Exact, because zero, replicate and reflect
    padding all commute with scaling. An ImageType scale would add an fp32 op that only runs on
    the CPU and splits the Neural Engine graph."""
    with torch.no_grad():
        conv.weight.mul_(1.0 / 255.0)


class TransformerExport(nn.Module):
    def __init__(self, transformer, width, height):
        super().__init__()
        self.t = transformer
        self.w, self.h = width, height
        self.crop = width % 4 != 0 or height % 4 != 0

    def forward(self, content, style):
        y = self.t(content, style) * 255.0
        # The network returns 4*ceil(n/4) rows and columns, for example 272 rows for 270.
        return y[:, :, :self.h, :self.w] if self.crop else y


def convert(module, example, inputs, outputs):
    return ct.convert(
        torch.jit.trace(module.eval(), example),
        inputs=inputs,
        outputs=outputs,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
        skip_model_load=True,
    )


def image_input(name, shape):
    return ct.ImageType(name=name, shape=shape, scale=1.0, color_layout=ct.colorlayout.RGB)


def save(ml, name, description, out):
    ml.author = "StyleCam"
    ml.license = "Apache-2.0 (Magenta weights)"
    ml.short_description = description
    path = os.path.join(out, f"{name}.mlpackage")
    shutil.rmtree(path, ignore_errors=True)
    ml.save(path)
    print("wrote", os.path.relpath(path, os.getcwd()))


def build_predictor(out):
    pred = load_predictor()
    fold_input_scale(pred.stem.conv)
    shapes = [(1, 3, PREDICTOR_HEIGHT, w) for w in PREDICTOR_WIDTHS]
    ml = convert(pred, (torch.rand(1, 3, 256, 256) * 255,),
                 [image_input("style_image", ct.EnumeratedShapes(shapes=shapes, default=(1, 3, 256, 256)))],
                 [ct.TensorType(name="bottleneck")])
    # Core ML refuses to compile an enumerated image input when the program parameter has a fixed
    # height. Marking it unknown is safe: the graph has no height-dependent ops, and every allowed
    # size gives even sizes at all stride-2 layers, so the traced TF SAME pads are exact.
    spec = ml.get_spec()
    spec.mlProgram.functions["main"].inputs[0].type.tensorType.dimensions[2].unknown.variadic = False
    ml = ct.models.MLModel(spec, weights_dir=ml.weights_dir, skip_model_load=True)
    ml.input_description["style_image"] = f"Style image, RGB 0-255: {PREDICTOR_RULE}"
    ml.output_description["bottleneck"] = "Style vector [1,100,1,1]"
    save(ml, "MagentaPredictor", f"Magenta style predictor. Input: {PREDICTOR_RULE}.", out)


def build_transformer(t, width, height, out, name, source):
    fold_input_scale(t.contract[0].conv)
    ml = convert(TransformerExport(t, width, height),
                 (torch.rand(1, 3, height, width) * 255, torch.zeros(1, BOTTLENECK_DIM, 1, 1)),
                 [image_input("content", (1, 3, height, width)),
                  ct.TensorType(name="style", shape=(1, BOTTLENECK_DIM, 1, 1), dtype=np.float32)],
                 [ct.ImageType(name="stylized", color_layout=ct.colorlayout.RGB)])
    ml.input_description["content"] = f"Frame, RGB 0-255, {width}x{height}"
    ml.input_description["style"] = "Style vector [1,100,1,1] from MagentaPredictor"
    ml.output_description["stylized"] = f"Stylized frame, {width}x{height}"
    ml.user_defined_metadata[PADDING_KEY] = t.padding_mode
    ml.user_defined_metadata[ANTIALIAS_KEY] = str(int(t.antialias))
    aa = ", anti-aliased" if t.antialias else ""
    save(ml, f"{name}_{width}x{height}",
         f"{source} arbitrary style transfer, {width}x{height}, {t.padding_mode} padding{aa}.", out)


def parse_size(s):
    w, h = s.lower().split("x")
    return int(w), int(h)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", nargs="+", default=DEFAULT_SIZES, help="transformer sizes, WxH")
    ap.add_argument("--padding", default="replicate", choices=["replicate", "zeros", "reflect"],
                    help="zeros matches @magenta/image exactly but leaves a dark border")
    ap.add_argument("--checkpoint", help="train_stable.py checkpoint; its padding overrides --padding")
    ap.add_argument("--name", default="MagentaTransformer", help="output name prefix")
    ap.add_argument("--out", default=MODELS)
    args = ap.parse_args()
    # TFSamePad's pads are meant to be baked into the trace.
    warnings.filterwarnings("ignore", category=torch.jit.TracerWarning)
    torch.set_grad_enabled(False)
    os.makedirs(args.out, exist_ok=True)
    if not args.checkpoint:
        build_predictor(args.out)
    for size in args.sizes:
        if args.checkpoint:
            t, source = load_checkpoint(args.checkpoint), "Fine-tuned Magenta"
        else:
            t, source = load_transformer(args.padding), "Magenta"
        build_transformer(t, *parse_size(size), args.out, args.name, source)


if __name__ == "__main__":
    main()
