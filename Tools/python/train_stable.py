"""Fine-tune the Magenta style transformer for temporal stability.

The student starts from the Magenta weights and is distilled to the frozen original for the same
content and style. The teacher's fine texture re-rolls with the crop position, and a shift-stable
student cannot match every roll: a per-pixel or full-resolution feature loss then rewards blur and
lower contrast, and matching the rolled texture's energy adds texture that flickers. So the target
is the teacher averaged over 4 positions of the stride-4 grid, compared with terms that do not
depend on where the grid falls:
  pix     smooth L1 on sigma 2 low-passed pixels (layout and tone)
  perc    VGG16 relu1_2 and relu2_2 pooled to 16 px cells (local texture energy)
  gram    VGG16 Gram matrices
  band    mid and low band luma energy and luma std, per image (guards against blur and flattening)
The student is also penalised for
  shift   student(shift(x)) != shift(student(x)), integer 1-3 px and subpixel shifts
  noise   student(x + n) != student(x), per-pixel and smooth noise

--arch same keeps the architecture. --arch antialias blurs before the stride-2 convs and upsamples
bilinearly (StyleTransformer(antialias=True)).

Styles: the paintings in Styles/ except the EVAL_STYLES of stability_metrics.py (predictor, h256
rule), random convex mixes of them, and the predictor on random COCO images. Content: random
256-384 px crops of COCO val2017 minus the held-out images of stability_metrics.py, with the
person-heavy content500/ oversampled.

Usage: uv run train_stable.py --arch antialias --data DIR --out DIR [--steps N] [--minutes M]
"""
import argparse
import glob
import json
import math
import os
import random
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

from stability_metrics import (EVAL_STYLES, VGG, bands, catalog, device, gauss, gram, heldout_paths,
                               style_vector, to_tensor)
from tfjs_weights import load_predictor, load_transformer

SIZES = [256, 288, 320, 352, 384]
MARGIN = 4
BORDER = 16
SOURCE = SIZES[-1] + 2 * MARGIN
PERSON_WEIGHT = 8
PIX_EPS = 0.01
PERC_POOL = (16, 8)
TEACHER_PHASES = [(0, 0), (0, 2), (2, 0), (2, 2)]


def load_crop(path):
    img = Image.open(path).convert("RGB")
    s = random.uniform(SOURCE, 1.5 * SOURCE) / min(img.size)
    img = img.resize((max(SOURCE, round(img.width * s)), max(SOURCE, round(img.height * s))), Image.BILINEAR)
    left, top = random.randint(0, img.width - SOURCE), random.randint(0, img.height - SOURCE)
    img = img.crop((left, top, left + SOURCE, top + SOURCE))
    if random.random() < 0.5:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    return to_tensor(img)[0]


def crop_batches(paths, weights, batch, workers):
    """Threads, not DataLoader processes: PIL releases the GIL, and worker processes left the
    interpreter hanging at exit on macOS."""
    def load():
        return torch.stack([load_crop(p) for p in random.choices(paths, weights, k=batch)])

    with ThreadPoolExecutor(workers) as pool:
        pending = [pool.submit(load) for _ in range(workers)]
        while True:
            pending.append(pool.submit(load))
            yield pending.pop(0).result()


def training_paths(data):
    held = {os.path.basename(p) for p in heldout_paths(data)}
    person = {os.path.basename(p) for p in glob.glob(os.path.join(data, "content500", "*.jpg"))}
    paths = [p for p in sorted(glob.glob(os.path.join(data, "val2017", "*.jpg"))) if os.path.basename(p) not in held]
    return paths, [PERSON_WEIGHT if os.path.basename(p) in person else 1 for p in paths]


@torch.no_grad()
def style_bank(predictor, paths, n_coco):
    paintings = torch.cat([style_vector(predictor, Image.open(p)) for sid, p in catalog().items() if sid not in EVAL_STYLES])
    coco = torch.cat([style_vector(predictor, Image.open(p)) for p in random.sample(paths, n_coco)])
    return paintings, coco


def sample_styles(paintings, coco, n):
    out = []
    for _ in range(n):
        r = random.random()
        if r < 0.45:
            out.append(paintings[random.randrange(len(paintings))])
        elif r < 0.75:
            pool = [paintings[i] for i in random.sample(range(len(paintings)), random.randint(2, 3))]
            if random.random() < 0.3:
                pool[-1] = coco[random.randrange(len(coco))]
            w = np.random.dirichlet(np.ones(len(pool)))
            out.append(sum(float(wi) * p for wi, p in zip(w, pool)))
        else:
            out.append(coco[random.randrange(len(coco))])
    return torch.stack(out)


def sample_at(t, y, x, size):
    """t sampled at rows y.., columns x.. (fractional, bilinear), size x size."""
    y0, x0 = math.floor(y), math.floor(x)
    fy, fx = y - y0, x - x0

    def crop(dy, dx):
        return t[:, :, y0 + dy:y0 + dy + size, x0 + dx:x0 + dx + size]

    top = crop(0, 0) * (1 - fx) + crop(0, 1) * fx if fx else crop(0, 0)
    if not fy:
        return top
    bottom = crop(1, 0) * (1 - fx) + crop(1, 1) * fx if fx else crop(1, 0)
    return top * (1 - fy) + bottom * fy


def shift_pair(region, size):
    """Inputs (a, b) and the output crops that must match: (oy_a, ox_a, oy_b, ox_b). Integer
    shifts are exact crops; subpixel ones sample a and b at -d/2 and +d/2 so both get the same
    interpolation blur."""
    if random.random() < 0.5:
        dy, dx = 0, 0
        while dy == 0 and dx == 0:
            dy, dx = random.randint(-3, 3), random.randint(-3, 3)
        b = sample_at(region, MARGIN + dy, MARGIN + dx, size)
        return None, b, (BORDER + dy, BORDER + dx, BORDER, BORDER)
    dy, dx = random.uniform(-1.5, 1.5), random.uniform(-1.5, 1.5)
    a = sample_at(region, MARGIN + dy / 2, MARGIN + dx / 2, size)
    b = sample_at(region, MARGIN - dy / 2, MARGIN - dx / 2, size)
    return a, b, (BORDER - dy / 2, BORDER - dx / 2, BORDER + dy / 2, BORDER + dx / 2)


def add_noise(x):
    n = x.shape[0]
    sigma = torch.rand(n, 2, 1, 1, 1, device=x.device) * (3 / 255)
    pixel = torch.randn_like(x) * sigma[:, 0]
    smooth = F.interpolate(torch.randn(n, 3, x.shape[2] // 4, x.shape[3] // 4, device=x.device),
                           size=x.shape[2:], mode="bilinear", align_corners=False) * sigma[:, 1]
    return (x + pixel + smooth).clamp(0, 1)


def charbonnier(d, eps=PIX_EPS):
    return ((d * d + eps * eps).sqrt() - eps).mean()


def distill_terms(y, t, fy, ft):
    """Squared relative errors on features and Gram matrices: an L1 or plain norm keeps a full-size
    gradient however close the student is (bf16 rounding is enough), and that drowns the stability
    terms."""
    perc = sum(((F.avg_pool2d(a, p) - F.avg_pool2d(b, p)) ** 2).mean() / (F.avg_pool2d(b, p) ** 2).mean().clamp_min(1e-6)
               for a, b, p in zip(fy, ft, PERC_POOL)) / len(PERC_POOL)
    g = sum((((gram(a) - gram(b)) ** 2).flatten(1).sum(1) / (gram(b) ** 2).flatten(1).sum(1)).mean()
            for a, b in zip(fy, ft)) / len(fy)
    bt = bands(t, BORDER)[:, 1:]
    band = ((bands(y, BORDER)[:, 1:] - bt).abs() / bt).mean()
    return charbonnier(gauss(y, 2) - gauss(t, 2)), perc, g, band


def lr_at(step, progress, lr, warmup=100):
    """Linear warmup, then cosine from lr to lr / 10 over progress 0..1."""
    if step < warmup:
        return lr * (step + 1) / warmup
    return lr * (0.1 + 0.45 * (1 + math.cos(math.pi * min(1.0, progress))))


def save(path, student, args, step):
    torch.save({"transformer": student.state_dict(), "padding": args.padding,
                "antialias": args.arch == "antialias", "step": step, "args": vars(args)}, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", choices=["same", "antialias"], default="antialias")
    ap.add_argument("--padding", default="replicate", choices=["replicate", "zeros", "reflect"])
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--name")
    ap.add_argument("--steps", type=int, default=30000, help="length of the lr schedule")
    ap.add_argument("--minutes", type=float, help="stop after this long, with the lr schedule fit to it")
    ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--bf16", action=argparse.BooleanOptionalAction, default=True,
                    help="bf16 autocast for the student and VGG, about 1.5x faster on MPS (fp16 gives NaN)")
    ap.add_argument("--w-pix", type=float, default=3.0)
    ap.add_argument("--w-perc", type=float, default=0.5)
    ap.add_argument("--w-gram", type=float, default=1.0)
    ap.add_argument("--w-band", type=float, default=1.0)
    ap.add_argument("--w-shift", type=float, default=12.0)
    ap.add_argument("--w-noise", type=float, default=12.0)
    ap.add_argument("--coco-styles", type=int, default=500)
    ap.add_argument("--log-every", type=int, default=25)
    ap.add_argument("--save-every", type=int, default=1000)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    name = args.name or args.arch
    os.makedirs(args.out, exist_ok=True)
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    dev = device()

    paths, weights = training_paths(args.data)
    predictor = load_predictor().to(dev)
    paintings, coco = style_bank(predictor, paths, args.coco_styles)
    del predictor

    teacher = load_transformer(args.padding).to(dev).requires_grad_(False)
    student = load_transformer(args.padding, antialias=args.arch == "antialias").to(dev)
    vgg = VGG().to(dev)
    opt = torch.optim.Adam(student.parameters(), lr=args.lr)

    log = open(os.path.join(args.out, f"{name}.jsonl"), "a")
    print(f"{len(paths)} content images, {len(paintings)} paintings, {len(coco)} COCO styles", flush=True)
    sums, count = {}, 0
    start = time.time()
    step = 0
    for batch in crop_batches(paths, weights, args.batch, args.workers):
        progress = step / args.steps
        if args.minutes:
            progress = max(progress, (time.time() - start) / (args.minutes * 60))
        if progress >= 1:
            break
        for g in opt.param_groups:
            g["lr"] = lr_at(step, progress, args.lr)
        size = random.choice(SIZES)
        o = random.randint(0, SOURCE - size - 2 * MARGIN)
        region = batch.to(dev, non_blocking=True)[:, :, o:o + size + 2 * MARGIN, o:o + size + 2 * MARGIN]
        x = region[:, :, MARGIN:MARGIN + size, MARGIN:MARGIN + size]
        style = sample_styles(paintings, coco, len(x))
        a, b, (ay, ax, by, bx) = shift_pair(region, size)
        noisy = add_noise(x)
        inputs = [x, noisy, b] + ([] if a is None else [a])
        with torch.no_grad():
            ts = teacher(torch.cat([region[:, :, MARGIN + dy:MARGIN + dy + size, MARGIN + dx:MARGIN + dx + size]
                                    for dy, dx in TEACHER_PHASES]), style.repeat(len(TEACHER_PHASES), 1, 1, 1))
            t = sum(F.pad(tp, (dx, 0, dy, 0), mode="replicate")[:, :, :size, :size]
                    for tp, (dy, dx) in zip(ts.split(len(x)), TEACHER_PHASES)) / len(TEACHER_PHASES)
        with torch.autocast(dev.type, dtype=torch.bfloat16, enabled=args.bf16):
            ys = student(torch.cat(inputs), style.repeat(len(inputs), 1, 1, 1)).float().split(len(x))
            y, yn, yb = ys[:3]
            ya = y if a is None else ys[3]
            fy, ft = [[f.float() for f in vgg(v)] for v in (y, t)]
        inner = size - 2 * BORDER
        losses = {}
        losses["pix"], losses["perc"], losses["gram"], losses["band"] = distill_terms(y, t, fy, ft)
        losses["shift"] = (sample_at(ya, ay, ax, inner) - sample_at(yb, by, bx, inner)).abs().mean()
        losses["noise"] = (sample_at(yn, BORDER, BORDER, inner) - sample_at(y.detach(), BORDER, BORDER, inner)).abs().mean()
        total = sum(getattr(args, f"w_{k}") * v for k, v in losses.items())
        opt.zero_grad(set_to_none=True)
        total.backward()
        opt.step()

        for k, v in losses.items():
            sums[k] = sums.get(k, 0.0) + v.item()
        count += 1
        step += 1
        if step % args.log_every == 0:
            row = {"step": step, "min": round((time.time() - start) / 60, 2), "lr": opt.param_groups[0]["lr"],
                   **{k: v / count for k, v in sums.items()}}
            print(json.dumps(row), flush=True)
            log.write(json.dumps(row) + "\n")
            log.flush()
            sums, count = {}, 0
            if dev.type == "mps":
                # Five crop sizes fragment the MPS cache; without this it grew past 35 GB.
                torch.mps.empty_cache()
        if step % args.save_every == 0:
            save(os.path.join(args.out, f"{name}_step{step}.pt"), student, args, step)
    save(os.path.join(args.out, f"{name}.pt"), student, args, step)
    print(f"{step} steps in {(time.time() - start) / 60:.1f} min, wrote {os.path.join(args.out, name + '.pt')}")


if __name__ == "__main__":
    main()
