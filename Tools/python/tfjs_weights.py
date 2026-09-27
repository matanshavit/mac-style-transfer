"""Read the TF.js frozen-model weights and load them into the PyTorch modules."""
import json
import os

import numpy as np
import torch

from fetch_magenta import CACHE
from magenta_torch import StylePredictor, StyleTransformer

_DTYPES = {"float32": np.float32, "int32": np.int32}


def read_tfjs_weights(model_dir):
    with open(os.path.join(model_dir, "weights_manifest.json")) as f:
        manifest = json.load(f)
    out = {}
    for group in manifest:
        buf = b"".join(open(os.path.join(model_dir, p), "rb").read() for p in group["paths"])
        offset = 0
        for w in group["weights"]:
            if "quantization" in w:
                raise NotImplementedError(f"quantized weight {w['name']}")
            dtype = np.dtype(_DTYPES[w["dtype"]])
            n = int(np.prod(w["shape"])) if w["shape"] else 1
            out[w["name"]] = np.frombuffer(buf, dtype, n, offset).reshape(w["shape"]).copy()
            offset += n * dtype.itemsize
        if offset != len(buf):
            raise ValueError(f"{model_dir}: used {offset} of {len(buf)} bytes")
    return out


class _Weights:
    def __init__(self, model_dir):
        self.w = read_tfjs_weights(model_dir)
        self.used = set()

    def raw(self, name):
        self.used.add(name)
        return torch.from_numpy(self.w[name].astype(np.float32))

    def conv(self, name):  # HWIO -> OIHW
        return self.raw(name).permute(3, 2, 0, 1).contiguous()

    def depthwise(self, name):  # [kh, kw, C, 1] -> [C, 1, kh, kw]
        return self.raw(name).permute(2, 3, 0, 1).contiguous()

    def check_all_used(self):
        unused = sorted(k for k, v in self.w.items() if k not in self.used and v.dtype == np.float32)
        if unused:
            raise ValueError(f"unused weights: {unused}")


def _load_bn(bn, src, prefix, gamma="gamma"):
    bn.weight.data.copy_(src.raw(f"{prefix}/{gamma}"))
    bn.bias.data.copy_(src.raw(f"{prefix}/beta"))
    bn.running_mean.copy_(src.raw(f"{prefix}/moving_mean"))
    bn.running_var.copy_(src.raw(f"{prefix}/moving_variance"))


def _load_convbn(m, src, prefix, depthwise=False):
    if depthwise:
        m.conv.weight.data.copy_(src.depthwise(f"{prefix}/depthwise_weights"))
    else:
        m.conv.weight.data.copy_(src.conv(f"{prefix}/weights"))
    _load_bn(m.bn, src, f"{prefix}/BatchNorm")


def load_predictor(cache=CACHE):
    src = _Weights(os.path.join(cache, "predictor"))
    m = StylePredictor().eval()
    _load_convbn(m.stem, src, "MobilenetV2/Conv")
    for i, block in enumerate(m.blocks):
        p = "MobilenetV2/expanded_conv" + (f"_{i}" if i else "")
        if block.expand is not None:
            _load_convbn(block.expand, src, f"{p}/expand")
        _load_convbn(block.depthwise, src, f"{p}/depthwise", depthwise=True)
        _load_convbn(block.project, src, f"{p}/project")
    _load_convbn(m.head, src, "MobilenetV2/Conv_1")
    m.bottleneck.weight.data.copy_(src.conv("mobilenet_conv/Conv/weights"))
    m.bottleneck.bias.data.copy_(src.raw("mobilenet_conv/Conv/biases"))
    src.check_all_used()
    return m


def _load_cin(norm, src, prefix):
    # In the graph, batchnorm/mul uses StyleNorm/Conv_1 (gamma) and batchnorm/sub uses StyleNorm/Conv (beta).
    sp = f"style_params/{prefix}/StyleNorm"
    norm.beta.weight.data.copy_(src.conv(f"{sp}/Conv/weights"))
    norm.beta.bias.data.copy_(src.raw(f"{sp}/Conv/biases"))
    norm.gamma.weight.data.copy_(src.conv(f"{sp}/Conv_1/weights"))
    norm.gamma.bias.data.copy_(src.raw(f"{sp}/Conv_1/biases"))


def load_transformer(padding_mode="replicate", cache=CACHE):
    src = _Weights(os.path.join(cache, "transformer"))
    m = StyleTransformer(padding_mode=padding_mode).eval()

    w = src.w
    assert w["transformer/contract/Pad/paddings"].tolist() == [[0, 0], [4, 4], [4, 4], [0, 0]]
    assert w["transformer/contract/Pad_1/paddings"].tolist() == [[0, 0], [1, 1], [1, 1], [0, 0]]
    assert int(w["transformer/expand/conv2/mul/x"]) == 2
    eps = float(src.raw("transformer/residual/residual1/conv1/StyleNorm/batchnorm/add/y"))
    assert all(abs(n.eps - eps) < 1e-12 for n in m.norm_layers()), eps

    for i, layer in enumerate(m.contract, start=1):
        p = f"transformer/contract/conv{i}"
        layer.conv.weight.data.copy_(src.conv(f"{p}/weights"))
        _load_bn(layer.bn, src, f"{p}/BatchNorm", gamma="Const")
    for r, block in enumerate(m.residual, start=1):
        for j, conv in enumerate([block.conv1, block.conv2], start=1):
            p = f"transformer/residual/residual{r}/conv{j}"
            conv.conv.weight.data.copy_(src.conv(f"{p}/weights"))
            _load_cin(conv.norm, src, p)
    for e, layer in enumerate(m.expand, start=1):
        p = f"transformer/expand/conv{e}/conv"
        layer.conv.weight.data.copy_(src.conv(f"{p}/weights"))
        _load_cin(layer.norm, src, p)
    src.check_all_used()
    return m
