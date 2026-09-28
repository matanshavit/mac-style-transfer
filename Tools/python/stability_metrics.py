"""Temporal stability and style fidelity of a style transformer.

  shift   motion-compensated mean abs output diff (0-255) after moving the input by 0.5..8 px
  noise   output diff / input diff for gaussian input noise, per pixel and smooth (drawn at 1/4
          resolution and upsampled, closer to camera noise after demosaic and compression)
  video   frame-to-frame luma change, output / input, on two 720p talking-head clips at 960x540,
          over all pixels and over the static background only (flicker without real motion)
  style   VGG16 Gram distance to the painting, relu3_3 distance to the input, texture (mean abs
          Laplacian of luma, 0-255), and distance to the shipped model's output. The input itself
          is printed as the no-style end of the Gram and texture scales.

MODEL is magenta-zeros, magenta-replicate (shipped), magenta-aa (anti-aliased architecture with
the Magenta weights), or a train_stable.py checkpoint. --data holds val2017/, heldout/ and video/.

Usage: uv run stability_metrics.py MODEL [MODEL ...] --data DIR [--out results.json] [--stills DIR]
"""
import argparse
import glob
import json
import os
import random

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import torchvision
from PIL import Image

from convert_coreml import predictor_input_size
from magenta_torch import load_checkpoint
from tfjs_weights import load_predictor, load_transformer

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
STYLES = os.path.join(REPO, "Styles")
REFERENCE = "magenta-replicate"
EVAL_STYLES = ["starry_night", "great_wave", "the_scream"]
VIDEOS = ["Johnny_1280x720_60.y4m", "KristenAndSara_1280x720_60.y4m"]
SHIFTS = [0.5, 1, 2, 3, 4, 8]
WINDOW, MARGIN, BORDER = 384, 8, 16
NOISE_SIGMA = 2 / 255
VIDEO_SIZE = (960, 540)
VIDEO_FRAMES, VIDEO_STEP = 100, 2
STATIC_THRESHOLD = 2 / 255
STILL_FRAME = 60


def device():
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def to_tensor(img):
    return torch.from_numpy(np.asarray(img, dtype=np.float32) / 255.0).permute(2, 0, 1)[None]


def to_image(t):
    return Image.fromarray((t.clamp(0, 1)[0].permute(1, 2, 0).cpu().numpy() * 255 + 0.5).astype(np.uint8))


def luma(rgb):
    return (0.299 * rgb[:, 0] + 0.587 * rgb[:, 1] + 0.114 * rgb[:, 2])[:, None]


def catalog():
    with open(os.path.join(STYLES, "catalog.json")) as f:
        return {s["id"]: os.path.join(STYLES, s["file"]) for s in json.load(f)}


def style_vector(predictor, img):
    img = img.convert("RGB")
    x = to_tensor(img.resize(predictor_input_size(*img.size), Image.BILINEAR))
    p = next(predictor.parameters())
    return predictor(x.to(p.device))


def heldout_paths(data, n=50):
    fixed = sorted(glob.glob(os.path.join(data, "heldout", "*.jpg")))
    names = {os.path.basename(p) for p in fixed}
    rest = [p for p in sorted(glob.glob(os.path.join(data, "val2017", "*.jpg"))) if os.path.basename(p) not in names]
    random.Random(0).shuffle(rest)
    return (fixed + rest)[:n]


def label(spec):
    return os.path.splitext(os.path.basename(spec))[0] if os.path.isfile(spec) else spec


def load_model(spec):
    if spec == "magenta-zeros":
        return load_transformer("zeros")
    if spec == "magenta-replicate":
        return load_transformer("replicate")
    if spec == "magenta-aa":
        return load_transformer("replicate", antialias=True)
    return load_checkpoint(spec)


class VGG(nn.Module):
    """VGG16 relu1_2, relu2_2, relu3_3, relu4_3 on [0, 1] RGB."""

    CUTS = (4, 9, 16, 23)

    def __init__(self):
        super().__init__()
        features = torchvision.models.vgg16(weights=torchvision.models.VGG16_Weights.IMAGENET1K_V1).features
        self.slices = nn.ModuleList(features[a:b] for a, b in zip((0,) + self.CUTS[:-1], self.CUTS))
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))
        self.requires_grad_(False)
        self.eval()

    def forward(self, x):
        x = (x - self.mean) / self.std
        out = []
        for s in self.slices:
            x = s(x)
            out.append(x)
        return out


def gram(f):
    n, c, h, w = f.shape
    f = f.reshape(n, c, h * w)
    return f @ f.transpose(1, 2) / (h * w)


def texture(y):
    k = torch.tensor([[0.0, 1.0, 0.0], [1.0, -4.0, 1.0], [0.0, 1.0, 0.0]], device=y.device).view(1, 1, 3, 3)
    return F.conv2d(interior(luma(y)), k).abs().mean().item() * 255


def rel(a, b):
    return ((a - b).flatten(1).norm(dim=1) / b.flatten(1).norm(dim=1)).mean().item()


def center_source(path):
    img = Image.open(path).convert("RGB")
    side = WINDOW + 2 * MARGIN
    s = side / min(img.size)
    img = img.resize((max(side, round(img.width * s)), max(side, round(img.height * s))), Image.LANCZOS)
    left, top = (img.width - side) // 2, (img.height - side) // 2
    return to_tensor(img.crop((left, top, left + side, top + side)))


def window(src, dy=0, dx=0):
    return src[:, :, MARGIN + dy:MARGIN + dy + WINDOW, MARGIN + dx:MARGIN + dx + WINDOW]


def interior(t, extra=0):
    b = BORDER + extra
    return t[:, :, b:t.shape[2] - b, b:t.shape[3] - b]


def shift_inputs(src):
    """The unshifted window, then per shift an x and a y pair (a, b). A 0.5 px pair is resampled
    at -0.25 and +0.25 px so both sides get the same blur."""
    base = window(src)
    xs, pairs = [base], []
    for s in SHIFTS:
        for axis in (3, 2):
            if s == 0.5:
                dy, dx = (0, 1) if axis == 3 else (1, 0)
                xs.append(0.75 * base + 0.25 * window(src, dy, dx))
                xs.append(0.75 * base + 0.25 * window(src, -dy, -dx))
                pairs.append((s, axis, len(xs) - 2, len(xs) - 1))
            else:
                xs.append(window(src, s, 0) if axis == 2 else window(src, 0, s))
                pairs.append((s, axis, 0, len(xs) - 1))
    return torch.cat(xs), pairs


def compensated_diff(ya, yb, s, axis):
    n = ya.shape[axis]
    if s == 0.5:
        a = 0.75 * ya.narrow(axis, 1, n - 2) + 0.25 * ya.narrow(axis, 0, n - 2)
        b = 0.75 * yb.narrow(axis, 1, n - 2) + 0.25 * yb.narrow(axis, 2, n - 2)
    else:
        a, b = ya.narrow(axis, s, n - s), yb.narrow(axis, 0, n - s)
    return (interior(a) - interior(b)).abs().mean().item() * 255


@torch.no_grad()
def run(model, x, style, batch=6):
    return torch.cat([model(x[i:i + batch], style.expand(len(x[i:i + batch]), -1, -1, -1))
                      for i in range(0, len(x), batch)])


@torch.no_grad()
def image_metrics(model, paths, styles, paintings, vgg, reference_out):
    dev = device()
    shift = {s: [] for s in SHIFTS}
    noise = {k: ([], []) for k in ("noise", "noise_smooth")}
    style_d, content_d, tex, ref_px, ref_vgg = [], [], [], [], []
    outputs = {}
    gen = torch.Generator().manual_seed(0)
    for i, path in enumerate(paths):
        src = center_source(path).to(dev)
        xs, pairs = shift_inputs(src)
        base = xs[:1]
        smooth = F.interpolate(torch.randn(1, 3, WINDOW // 4, WINDOW // 4, generator=gen), scale_factor=4.0,
                               mode="bilinear", align_corners=False)
        noisy = {"noise": base + torch.randn(base.shape, generator=gen).to(dev) * NOISE_SIGMA,
                 "noise_smooth": base + smooth.to(dev) * NOISE_SIGMA}
        noisy = {k: v.clamp(0, 1) for k, v in noisy.items()}
        feats_in = vgg(base)
        for sid, style in styles.items():
            ys = run(model, torch.cat([xs] + list(noisy.values())), style)
            for s, axis, a, b in pairs:
                shift[s].append(compensated_diff(ys[a:a + 1], ys[b:b + 1], s, axis))
            y = ys[:1]
            for j, (k, x) in enumerate(noisy.items()):
                yn = ys[len(xs) + j:len(xs) + j + 1]
                noise[k][0].append((interior(yn) - interior(y)).abs().mean().item())
                noise[k][1].append((interior(x) - interior(base)).abs().mean().item())
            feats = vgg(y)
            style_d.append(np.mean([rel(gram(f), g) for f, g in zip(feats, paintings[sid])]))
            content_d.append(rel(feats[2], feats_in[2]))
            tex.append(texture(y))
            outputs[(i, sid)] = y.half().cpu()
            if reference_out is not None:
                r = reference_out[(i, sid)].float().to(dev)
                ref_px.append((y - r).abs().mean().item() * 255)
                ref_vgg.append(rel(feats[2], vgg(r)[2]))
    metrics = {
        "shift": {str(s): float(np.mean(v)) for s, v in shift.items()},
        **{f"{k}_ratio": float(np.sum(o) / np.sum(i)) for k, (o, i) in noise.items()},
        **{f"{k}_out": float(np.mean(o) * 255) for k, (o, i) in noise.items()},
        "gram_to_painting": float(np.mean(style_d)),
        "relu33_to_input": float(np.mean(content_d)),
        "texture": float(np.mean(tex)),
    }
    if reference_out is not None:
        metrics["px_to_shipped"] = float(np.mean(ref_px))
        metrics["relu33_to_shipped"] = float(np.mean(ref_vgg))
    return metrics, outputs


@torch.no_grad()
def unstyled_reference(paths, paintings, vgg):
    """The Gram distance and texture of the unstyled input."""
    dev = device()
    g, tex = [], []
    for path in paths:
        x = window(center_source(path).to(dev))
        feats = vgg(x)
        g += [np.mean([rel(gram(f), p) for f, p in zip(feats, ps)]) for ps in paintings.values()]
        tex.append(texture(x))
    return {"gram_to_painting": float(np.mean(g)), "texture": float(np.mean(tex))}


def read_y4m(path, count, step):
    with open(path, "rb") as f:
        header = f.readline().split()
        w = int(next(t[1:] for t in header if t.startswith(b"W")))
        h = int(next(t[1:] for t in header if t.startswith(b"H")))
        size = w * h * 3 // 2
        frames = []
        for i in range(count * step):
            f.readline()
            buf = f.read(size)
            if i % step:
                continue
            yuv = np.frombuffer(buf, np.uint8).astype(np.float32)
            y = yuv[:w * h].reshape(h, w)
            u = yuv[w * h:w * h + size // 6].reshape(h // 2, w // 2).repeat(2, 0).repeat(2, 1) - 128
            v = yuv[w * h + size // 6:].reshape(h // 2, w // 2).repeat(2, 0).repeat(2, 1) - 128
            rgb = np.stack([y + 1.402 * v, y - 0.344136 * u - 0.714136 * v, y + 1.772 * u])
            x = torch.from_numpy(np.clip(rgb, 0, 255) / 255.0)[None].float()
            frames.append(F.interpolate(x, size=VIDEO_SIZE[::-1], mode="bilinear", antialias=True, align_corners=False))
    return torch.cat(frames)


def static_mask(dy):
    local = F.avg_pool2d(dy, 9, 1, 4, count_include_pad=False)
    return F.max_pool2d(local, 15, 1, 7) < STATIC_THRESHOLD


@torch.no_grad()
def video_metrics(model, videos, styles):
    dev = device()
    rows = {}
    stills = {}
    for name, frames in videos.items():
        yin = interior(luma(frames))
        din = (yin[1:] - yin[:-1]).abs()
        mask = static_mask(din)
        sums = np.zeros(4)
        for sid, style in styles.items():
            out = torch.cat([run(model, frames[i:i + 4].to(dev), style).cpu() for i in range(0, len(frames), 4)])
            yout = interior(luma(out))
            dout = (yout[1:] - yout[:-1]).abs()
            sums += [t.sum().item() for t in (dout, din, dout * mask, din * mask)]
            stills[(name, sid)] = (out[STILL_FRAME:STILL_FRAME + 1], out[STILL_FRAME - 1:STILL_FRAME])
        n_all, n_static = din.numel(), mask.sum().item()
        rows[name] = {
            "ratio_all": float(sums[0] / sums[1]),
            "ratio_static": float(sums[2] / sums[3]),
            "out_static": float(sums[2] / n_static / len(styles) * 255),
            "in_static": float(sums[3] / n_static / len(styles) * 255),
            "static_fraction": n_static / n_all,
        }
    return rows, stills


def save_stills(out_dir, names, videos, image_inputs, image_outputs, video_outputs):
    os.makedirs(out_dir, exist_ok=True)
    for sid in EVAL_STYLES:
        rows = [[image_inputs[i]] + [image_outputs[n][(i, sid)].float() for n in names] for i in sorted(image_inputs)]
        grid(rows).save(os.path.join(out_dir, f"{sid}_images.jpg"), quality=92)
        rows = [[videos[v][STILL_FRAME:STILL_FRAME + 1]] + [video_outputs[n][(v, sid)][0] for n in names] for v in videos]
        grid(rows).save(os.path.join(out_dir, f"{sid}_video.jpg"), quality=92)
        flicker = []
        for v in videos:
            din = (luma(videos[v][STILL_FRAME:STILL_FRAME + 1]) - luma(videos[v][STILL_FRAME - 1:STILL_FRAME])).abs()
            row = [din]
            for n in names:
                cur, prev = video_outputs[n][(v, sid)]
                row.append((luma(cur) - luma(prev)).abs())
            flicker.append([(t * 4).expand(-1, 3, -1, -1) for t in row])
        grid(flicker).save(os.path.join(out_dir, f"{sid}_video_diff_x4.jpg"), quality=92)
    print("stills in", out_dir, "columns: input,", ", ".join(names))


def grid(rows):
    tiles = [[to_image(t) for t in row] for row in rows]
    w, h = tiles[0][0].size
    img = Image.new("RGB", (w * len(tiles[0]), h * len(tiles)))
    for r, row in enumerate(tiles):
        for c, t in enumerate(row):
            img.paste(t, (c * w, r * h))
    return img


def print_tables(results, unstyled):
    names = list(results)
    print("\nshift sensitivity, motion-compensated mean abs diff (0-255)")
    print("| model | " + " | ".join(f"{s} px" for s in SHIFTS) + " |")
    for n in names:
        print(f"| {n} | " + " | ".join(f"{results[n]['images']['shift'][str(s)]:.2f}" for s in SHIFTS) + " |")
    print(f"\nnoise (sigma 2/255) and style fidelity; the input has Gram {unstyled['gram_to_painting']:.4f}, "
          f"texture {unstyled['texture']:.2f}")
    print("| model | noise out/in | noise out (0-255) | smooth noise out/in | smooth noise out | "
          "Gram to painting | relu3_3 to input | texture | px to shipped | relu3_3 to shipped |")
    for n in names:
        m = results[n]["images"]
        print(f"| {n} | {m['noise_ratio']:.3f} | {m['noise_out']:.2f} | {m['noise_smooth_ratio']:.3f} | "
              f"{m['noise_smooth_out']:.2f} | {m['gram_to_painting']:.4f} | "
              f"{m['relu33_to_input']:.4f} | {m['texture']:.2f} | {m.get('px_to_shipped', 0):.2f} | "
              f"{m.get('relu33_to_shipped', 0):.4f} |")
    print("\nvideo, 960x540 at 30 fps: mean |dY_out| / mean |dY_in|, and static background out |dY| (0-255)")
    print("| model | video | ratio all | ratio static | out static | in static | static frac |")
    for n in names:
        for v, m in results[n]["video"].items():
            print(f"| {n} | {v.split('_')[0]} | {m['ratio_all']:.3f} | {m['ratio_static']:.3f} | "
                  f"{m['out_static']:.2f} | {m['in_static']:.2f} | {m['static_fraction']:.2f} |")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("models", nargs="+")
    ap.add_argument("--data", default=os.path.join(REPO, "data"))
    ap.add_argument("--images", type=int, default=50)
    ap.add_argument("--out")
    ap.add_argument("--stills", help="write side-by-side stills here")
    args = ap.parse_args()
    dev = device()

    predictor = load_predictor().to(dev)
    vgg = VGG().to(dev)
    paths = catalog()
    styles, paintings = {}, {}
    with torch.no_grad():
        for sid in EVAL_STYLES:
            img = Image.open(paths[sid]).convert("RGB")
            styles[sid] = style_vector(predictor, img)
            s = WINDOW / min(img.size)
            paint = to_tensor(img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)).to(dev)
            paintings[sid] = [gram(f) for f in vgg(paint)]
    images = heldout_paths(args.data, args.images)
    videos = {v: read_y4m(os.path.join(args.data, "video", v), VIDEO_FRAMES, VIDEO_STEP) for v in VIDEOS}

    specs = [REFERENCE] + [m for m in args.models if m != REFERENCE]
    results, image_outputs, video_outputs = {}, {}, {}
    reference_out = None
    for spec in specs:
        name = label(spec)
        model = load_model(spec).to(dev)
        im, image_outputs[name] = image_metrics(model, images, styles, paintings, vgg, reference_out)
        if reference_out is None:
            reference_out = image_outputs[name]
        results[name] = {"images": im}
        results[name]["video"], video_outputs[name] = video_metrics(model, videos, styles)
        print(name, json.dumps(results[name]))
    unstyled = unstyled_reference(images, paintings, vgg)
    print_tables(results, unstyled)
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"input": unstyled, **results}, f, indent=1)
    if args.stills:
        inputs = {i: window(center_source(images[i])) for i in (0, 1)}
        shown = [label(m) for m in specs if m in args.models]
        save_stills(args.stills, shown, videos, inputs, image_outputs, video_outputs)


if __name__ == "__main__":
    main()
