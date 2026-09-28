"""Temporal stability and style fidelity of a style transformer. Diffs are on a 0-255 scale.

  shift   motion-compensated mean abs output diff after moving the input by 1, 2, 3, 4 and 8 px.
          The outputs for all 16 shifts of 0-3 px in x and y, aligned and averaged, are the
          position-stable part M of the output; re-roll is the mean distance to M.
  noise   output diff / input diff for gaussian input noise, per pixel and smooth (drawn at 1/4
          resolution and upsampled), on COCO crops
  bands   luma energy of the output and of M: top octave (mean abs Laplacian), mid (DoG sigma
          1-3), low (DoG sigma 3-8), and luma std. The top octave of the output alone includes
          the re-roll, so compare M.
  style   VGG16 Gram distance to the painting and to the shipped model's output, relu3_3 distance
          to the input and to the shipped output, and sigma 2 low-pass distance to the shipped
          output (layout and tone drift). The input is printed as the no-style end.
  video   two 720p talking-head clips at 960x540 and 30 fps: flow-warped luma error on moving
          pixels (RAFT-small, over 1 px and forward-backward consistent), frame-to-frame luma
          change on the static background, and output / input change for gaussian noise there

MODEL is magenta-zeros, magenta-replicate (shipped), magenta-aa (anti-aliased architecture with
the Magenta weights), or a train_stable.py checkpoint. --data holds val2017/, heldout/ and video/.
EVAL_STYLES are held out of train_stable.py.

Usage: uv run stability_metrics.py MODEL [MODEL ...] --data DIR [--out results.json] [--stills DIR]
"""
import argparse
import glob
import json
import math
import os
import random
from collections import defaultdict

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
PHASES = [(dy, dx) for dy in range(4) for dx in range(4)]
FAR = [(0, 4), (4, 0), (0, 8), (8, 0)]
SHIFTS = [1, 2, 3, 4, 8]
BANDS = ["top", "mid", "low", "std"]
WINDOW, MARGIN, BORDER = 384, 8, 16
NOISE_SIGMA = 2 / 255
VIDEO_SIZE = (960, 540)
VIDEO_FRAMES, VIDEO_STEP = 100, 2
FLOW_SIZE = (480, 272)
MOVING_FLOW, MAX_INCONSISTENCY = 1.0, 0.5
NOISE_FRAME_STEP = 10
STATIC_THRESHOLD = 2 / 255
STILL_FRAME = 60
STILL_IMAGES = (0, 1, 13, 17)
LAPLACIAN = torch.tensor([[0.0, 1.0, 0.0], [1.0, -4.0, 1.0], [0.0, 1.0, 0.0]]).view(1, 1, 3, 3)


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


def gauss(x, sigma):
    r = math.ceil(3 * sigma)
    t = torch.arange(-r, r + 1, device=x.device, dtype=x.dtype)
    k = torch.exp(-t * t / (2 * sigma * sigma))
    k = k / k.sum()
    c = x.shape[1]
    x = F.conv2d(F.pad(x, (r, r, 0, 0), mode="replicate"), k.view(1, 1, 1, -1).expand(c, 1, 1, -1), groups=c)
    return F.conv2d(F.pad(x, (0, 0, r, r), mode="replicate"), k.view(1, 1, -1, 1).expand(c, 1, -1, 1), groups=c)


def interior(t, b=BORDER):
    return t[:, :, b:t.shape[2] - b, b:t.shape[3] - b]


def bands(y, border=BORDER):
    """Per image [N, 4]: top-octave, mid and low band energy of luma, and luma std, over the interior."""
    y = luma(y)
    g1, g3, g8 = gauss(y, 1), gauss(y, 3), gauss(y, 8)
    top = F.pad(F.conv2d(y, LAPLACIAN.to(y.device, y.dtype)), (1, 1, 1, 1))
    mean = [interior(t, border).mean((1, 2, 3)) for t in (top.abs(), (g1 - g3).abs(), (g3 - g8).abs())]
    return torch.stack(mean + [interior(y, border).std((1, 2, 3))], 1)


def rel(a, b):
    return ((a - b).flatten(1).norm(dim=1) / b.flatten(1).norm(dim=1)).mean().item()


def mad(a, b):
    """On the CPU: on MPS a broadcast diff of the phase stack now and then reduced to a wrong value."""
    return (a.cpu() - b.cpu()).abs().mean().item() * 255


def center_source(path):
    img = Image.open(path).convert("RGB")
    side = WINDOW + 2 * MARGIN
    s = side / min(img.size)
    img = img.resize((max(side, round(img.width * s)), max(side, round(img.height * s))), Image.LANCZOS)
    left, top = (img.width - side) // 2, (img.height - side) // 2
    return to_tensor(img.crop((left, top, left + side, top + side)))


def window(src, dy=0, dx=0):
    return src[:, :, MARGIN + dy:MARGIN + dy + WINDOW, MARGIN + dx:MARGIN + dx + WINDOW]


def aligned_phases(ys):
    """Outputs for the PHASES windows cropped to the same source pixels."""
    return torch.cat([ys[j:j + 1, :, 3 - dy:WINDOW - dy, 3 - dx:WINDOW - dx] for j, (dy, dx) in enumerate(PHASES)])


def compensated_diff(ya, yb, s, axis):
    n = ya.shape[axis]
    return mad(interior(ya.narrow(axis, s, n - s)), interior(yb.narrow(axis, 0, n - s)))


@torch.no_grad()
def run(model, x, style, batch=6):
    return torch.cat([model(x[i:i + batch], style.expand(len(x[i:i + batch]), -1, -1, -1))
                      for i in range(0, len(x), batch)])


@torch.no_grad()
def image_metrics(model, paths, styles, paintings, vgg, reference_out):
    dev = device()
    acc = defaultdict(list)
    noise = {k: ([], []) for k in ("noise", "noise_smooth")}
    outputs = {}
    gen = torch.Generator().manual_seed(0)
    for i, path in enumerate(paths):
        src = center_source(path).to(dev)
        base = window(src)
        smooth = F.interpolate(torch.randn(1, 3, WINDOW // 4, WINDOW // 4, generator=gen), scale_factor=4.0,
                               mode="bilinear", align_corners=False)
        noisy = [base + torch.randn(base.shape, generator=gen).to(dev) * NOISE_SIGMA, base + smooth.to(dev) * NOISE_SIGMA]
        noisy = [v.clamp(0, 1) for v in noisy]
        xs = torch.cat([window(src, dy, dx) for dy, dx in PHASES + FAR] + noisy)
        feats_in = vgg(base)
        for sid, style in styles.items():
            ys = run(model, xs, style)
            y = ys[:1]
            al = aligned_phases(ys)
            m = al.mean(0, keepdim=True)
            acc["reroll"].append(mad(interior(al), interior(m)))
            for s in (1, 2, 3):
                for p in ((0, s), (s, 0)):
                    j = PHASES.index(p)
                    acc[f"shift_{s}"].append(mad(interior(al[:1]), interior(al[j:j + 1])))
            for j, (dy, dx) in enumerate(FAR, start=len(PHASES)):
                acc[f"shift_{dx or dy}"].append(compensated_diff(y, ys[j:j + 1], dx or dy, 3 if dx else 2))
            acc["bands_y"].append(bands(al[:1]).cpu().numpy() * 255)
            acc["bands_m"].append(bands(m).cpu().numpy() * 255)
            for j, ((o, n), x) in enumerate(zip(noise.values(), noisy), start=len(PHASES) + len(FAR)):
                o.append(mad(interior(ys[j:j + 1]), interior(y)))
                n.append(mad(interior(x), interior(base)))
            feats = vgg(y)
            acc["gram_to_painting"].append(np.mean([rel(gram(f), g) for f, g in zip(feats, paintings[sid])]))
            acc["relu33_to_input"].append(rel(feats[2], feats_in[2]))
            outputs[(i, sid)] = y.half().cpu()
            if reference_out is not None:
                r = reference_out[(i, sid)].float().to(dev)
                fr = vgg(r)
                acc["gram_to_shipped"].append(np.mean([rel(gram(f), gram(g)) for f, g in zip(feats, fr)]))
                acc["relu33_to_shipped"].append(rel(feats[2], fr[2]))
                acc["lowpass_to_shipped"].append(mad(interior(gauss(y, 2)), interior(gauss(r, 2))))
    metrics = {
        "shift": {str(s): float(np.mean(acc[f"shift_{s}"])) for s in SHIFTS},
        "reroll": float(np.mean(acc["reroll"])),
        "bands": dict(zip(BANDS, np.concatenate(acc["bands_y"]).mean(0).tolist())),
        "bands_stable": dict(zip(BANDS, np.concatenate(acc["bands_m"]).mean(0).tolist())),
        **{f"{k}_ratio": float(np.sum(o) / np.sum(n)) for k, (o, n) in noise.items()},
    }
    for k in ("gram_to_painting", "relu33_to_input", "gram_to_shipped", "relu33_to_shipped", "lowpass_to_shipped"):
        metrics[k] = float(np.mean(acc[k])) if acc[k] else 0.0
    return metrics, outputs


@torch.no_grad()
def unstyled_reference(paths, paintings, vgg):
    """The Gram distance and band energies of the unstyled input."""
    dev = device()
    g, b = [], []
    for path in paths:
        x = window(center_source(path).to(dev))
        feats = vgg(x)
        g += [np.mean([rel(gram(f), p) for f, p in zip(feats, ps)]) for ps in paintings.values()]
        b.append(bands(x).cpu().numpy() * 255)
    return {"gram_to_painting": float(np.mean(g)), "bands": dict(zip(BANDS, np.concatenate(b).mean(0).tolist()))}


def read_y4m(path, count, step):
    """I420 y4m as RGB in [0, 1]. Limited range unless the header says XCOLORRANGE=FULL."""
    with open(path, "rb") as f:
        header = f.readline().split()
        w = int(next(t[1:] for t in header if t.startswith(b"W")))
        h = int(next(t[1:] for t in header if t.startswith(b"H")))
        full = b"XCOLORRANGE=FULL" in header
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
            if not full:
                y, u, v = (y - 16) * (255 / 219), u * (255 / 224), v * (255 / 224)
            rgb = np.stack([y + 1.402 * v, y - 0.344136 * u - 0.714136 * v, y + 1.772 * u])
            x = torch.from_numpy(np.clip(rgb, 0, 255) / 255.0)[None].float()
            frames.append(F.interpolate(x, size=VIDEO_SIZE[::-1], mode="bilinear", antialias=True, align_corners=False))
    return torch.cat(frames)


def static_mask(dy):
    local = F.avg_pool2d(dy, 9, 1, 4, count_include_pad=False)
    return F.max_pool2d(local, 15, 1, 7) < STATIC_THRESHOLD


def warp(img, flow):
    n, _, h, w = img.shape
    yy, xx = torch.meshgrid(torch.arange(h, dtype=img.dtype), torch.arange(w, dtype=img.dtype), indexing="ij")
    gx = (xx + flow[:, 0]) / (w - 1) * 2 - 1
    gy = (yy + flow[:, 1]) / (h - 1) * 2 - 1
    return F.grid_sample(img, torch.stack([gx, gy], -1), mode="bilinear", padding_mode="border", align_corners=True)


@torch.no_grad()
def motion(frames):
    """Per frame pair (t-1, t): flow from t back to t-1, and a mask of consistent moving pixels."""
    dev = device()
    raft = torchvision.models.optical_flow.raft_small(
        weights=torchvision.models.optical_flow.Raft_Small_Weights.DEFAULT).to(dev).eval()
    small = F.interpolate(frames, size=FLOW_SIZE[::-1], mode="bilinear", antialias=True, align_corners=False) * 2 - 1
    scale = torch.tensor([VIDEO_SIZE[0] / FLOW_SIZE[0], VIDEO_SIZE[1] / FLOW_SIZE[1]]).view(1, 2, 1, 1)
    back, fwd = [], []
    for t in range(1, len(frames)):
        a, b = small[t:t + 1].to(dev), small[t - 1:t].to(dev)
        back.append(raft(a, b)[-1].cpu())
        fwd.append(raft(b, a)[-1].cpu())

    def full(f):
        return F.interpolate(torch.cat(f), size=VIDEO_SIZE[::-1], mode="bilinear", align_corners=False) * scale

    back, fwd = full(back), full(fwd)
    consistent = (back + warp(fwd, back)).norm(dim=1, keepdim=True) < MAX_INCONSISTENCY
    moving = consistent & (back.norm(dim=1, keepdim=True) > MOVING_FLOW)
    moving[:, :, :BORDER] = moving[:, :, -BORDER:] = False
    moving[:, :, :, :BORDER] = moving[:, :, :, -BORDER:] = False
    return back, moving


def warped_error(y, flow, mask):
    y = luma(y)
    e = (y[1:] - warp(y[:-1], flow)).abs()
    return (e * mask).sum().item(), mask.sum().item()


@torch.no_grad()
def video_metrics(model, videos, flows, styles):
    dev = device()
    rows, stills = {}, {}
    for name, frames in videos.items():
        flow, moving = flows[name]
        yin = interior(luma(frames))
        din = (yin[1:] - yin[:-1]).abs()
        mask = static_mask(din)
        idx = list(range(0, len(frames) - 1, NOISE_FRAME_STEP))
        gen = torch.Generator().manual_seed(0)
        noisy = (frames[idx] + torch.randn(frames[idx].shape, generator=gen) * NOISE_SIGMA).clamp(0, 1)
        nmask = mask[idx]
        nin = (interior(luma(noisy)) - interior(luma(frames[idx]))).abs()
        sums = defaultdict(float)
        for sid, style in styles.items():
            out = torch.cat([run(model, frames[i:i + 4].to(dev), style).cpu() for i in range(0, len(frames), 4)])
            yout = interior(luma(out))
            dout = (yout[1:] - yout[:-1]).abs()
            sums["static_out"] += (dout * mask).sum().item()
            sums["static_in"] += (din * mask).sum().item()
            e, n = warped_error(out, flow, moving)
            sums["moving_out"] += e
            sums["moving_n"] += n
            yn = interior(luma(torch.cat([run(model, noisy[i:i + 4].to(dev), style).cpu() for i in range(0, len(noisy), 4)])))
            sums["noise_out"] += ((yn - yout[idx]).abs() * nmask).sum().item()
            sums["noise_in"] += (nin * nmask).sum().item()
            stills[(name, sid)] = (out[STILL_FRAME:STILL_FRAME + 1], out[STILL_FRAME - 1:STILL_FRAME])
        n_static = mask.sum().item() * len(styles)
        e_in, n_in = warped_error(frames, flow, moving)
        rows[name] = {
            "moving_out": sums["moving_out"] / sums["moving_n"] * 255,
            "moving_in": e_in / n_in * 255,
            "moving_fraction": n_in / moving.numel(),
            "static_out": sums["static_out"] / n_static * 255,
            "static_in": sums["static_in"] / n_static * 255,
            "static_fraction": mask.float().mean().item(),
            "wall_noise_ratio": sums["noise_out"] / sums["noise_in"],
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
    ref = results[names[0]]["images"]
    print("\nshift: motion-compensated mean abs diff, and re-roll (distance to the position-stable part)")
    print("| model | " + " | ".join(f"{s} px" for s in SHIFTS) + " | re-roll |")
    for n in names:
        m = results[n]["images"]
        print(f"| {n} | " + " | ".join(f"{m['shift'][str(s)]:.2f}" for s in SHIFTS) + f" | {m['reroll']:.2f} |")
    ub = unstyled["bands"]
    print(f"\nbands: output / stable part M, ratio of M to {names[0]} in brackets; the input has Gram "
          f"{unstyled['gram_to_painting']:.3f}, top {ub['top']:.2f}, mid {ub['mid']:.2f}, low {ub['low']:.2f}, "
          f"std {ub['std']:.1f}")
    print("| model | top | mid | low | luma std | Gram to painting | Gram to shipped | relu3_3 to shipped | "
          "low-pass px to shipped |")
    for n in names:
        m = results[n]["images"]
        b, s, rs = m["bands"], m["bands_stable"], ref["bands_stable"]
        cells = [f"{b[k]:.2f} / {s[k]:.2f} ({s[k] / rs[k]:.2f})" for k in ("top", "mid", "low")]
        cells.append(f"{s['std']:.1f} ({s['std'] / rs['std']:.2f})")
        cells += [f"{m[k]:.3f}" for k in ("gram_to_painting", "gram_to_shipped", "relu33_to_shipped")]
        cells.append(f"{m['lowpass_to_shipped']:.2f}")
        print(f"| {n} | " + " | ".join(cells) + " |")
    print("\nnoise sigma 2/255, output / input change: COCO per pixel and smooth, static wall of each clip")
    print("| model | COCO | COCO smooth | " + " | ".join(v.split("_")[0] for v in VIDEOS) + " |")
    for n in names:
        m, v = results[n]["images"], results[n]["video"]
        print(f"| {n} | {m['noise_ratio']:.2f} | {m['noise_smooth_ratio']:.2f} | "
              + " | ".join(f"{v[k]['wall_noise_ratio']:.2f}" for k in VIDEOS) + " |")
    print("\nvideo, 960x540 at 30 fps: warped luma error on moving pixels and luma change on the static "
          "background, output (input)")
    print("| model | " + " | ".join(f"{v.split('_')[0]} moving | {v.split('_')[0]} static" for v in VIDEOS) + " |")
    for n in names:
        v = results[n]["video"]
        print(f"| {n} | " + " | ".join(f"{v[k]['moving_out']:.2f} ({v[k]['moving_in']:.2f}) | "
                                       f"{v[k]['static_out']:.2f} ({v[k]['static_in']:.2f})" for k in VIDEOS) + " |")
    v = results[names[0]]["video"]
    print("moving / static fraction: " + ", ".join(
        f"{k.split('_')[0]} {v[k]['moving_fraction']:.3f} / {v[k]['static_fraction']:.2f}" for k in VIDEOS))


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
    flows = {v: motion(frames) for v, frames in videos.items()}

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
        results[name]["video"], video_outputs[name] = video_metrics(model, videos, flows, styles)
        print(name, json.dumps(results[name]), flush=True)
    unstyled = unstyled_reference(images, paintings, vgg)
    print_tables(results, unstyled)
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"input": unstyled, **results}, f, indent=1)
    if args.stills:
        inputs = {i: window(center_source(images[i])) for i in STILL_IMAGES if i < len(images)}
        shown = [label(m) for m in specs if m in args.models]
        save_stills(args.stills, shown, videos, inputs, image_outputs, video_outputs)


if __name__ == "__main__":
    main()
