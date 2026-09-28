"""PyTorch port of the Magenta arbitrary image stylization network (Ghiasi et al. 2017), as
shipped in the @magenta/image 0.2.1 TF.js checkpoints. NCHW, RGB images in [0, 1].

StylePredictor:   style image [N,3,H,W]           -> bottleneck [N,100,1,1]
StyleTransformer: content [N,3,H,W], bottleneck    -> stylized [N,3,4*ceil(H/4),4*ceil(W/4)]

StyleTransformer(antialias=True) is the shift-stable variant for fine-tuning (train_stable.py): a
[1,2,1] binomial blur before each stride-2 conv (Zhang 2019, "Making Convolutional Networks
Shift-Invariant Again") and bilinear instead of nearest upsampling. It has the same parameters,
so the Magenta weights load into it unchanged.
"""
import torch
import torch.nn as nn
import torch.nn.functional as F

BOTTLENECK_DIM = 100


class TFSamePad(nn.Module):
    """TF 'SAME' padding for a strided conv: total // 2 before, the rest after."""

    def __init__(self, kernel_size, stride):
        super().__init__()
        self.k = kernel_size
        self.s = stride

    def _pad(self, n):
        # max((ceil(n/s) - 1) * s + k - n, 0) == max(k - (n % s or s), 0). Branching on n % s
        # keeps the pads Python constants under torch.jit.trace.
        rem = next(r for r in range(self.s) if n % self.s == r)
        total = max(self.k - (rem or self.s), 0)
        return total // 2, total - total // 2

    def forward(self, x):
        top, bottom = self._pad(x.shape[-2])
        left, right = self._pad(x.shape[-1])
        return F.pad(x, (left, right, top, bottom))


class ConvBN(nn.Module):
    def __init__(self, cin, cout, k=1, stride=1, groups=1, relu6=True):
        super().__init__()
        self.pad = TFSamePad(k, stride) if stride > 1 else nn.Identity()
        self.conv = nn.Conv2d(cin, cout, k, stride, k // 2 if stride == 1 else 0, groups=groups, bias=False)
        self.bn = nn.BatchNorm2d(cout, eps=1e-3)
        self.act = nn.ReLU6() if relu6 else nn.Identity()

    def forward(self, x):
        return self.act(self.bn(self.conv(self.pad(x))))


class InvertedResidual(nn.Module):
    def __init__(self, cin, cout, stride, expansion):
        super().__init__()
        hidden = cin * expansion
        self.expand = ConvBN(cin, hidden) if expansion != 1 else None
        self.depthwise = ConvBN(hidden, hidden, 3, stride, groups=hidden)
        self.project = ConvBN(hidden, cout, relu6=False)
        self.use_residual = stride == 1 and cin == cout

    def forward(self, x):
        h = x if self.expand is None else self.expand(x)
        h = self.project(self.depthwise(h))
        return x + h if self.use_residual else h


# (expansion, channels, repeats, first stride): standard MobileNetV2.
MOBILENET_V2 = [(1, 16, 1, 1), (6, 24, 2, 2), (6, 32, 3, 2), (6, 64, 4, 2), (6, 96, 3, 1), (6, 160, 3, 2), (6, 320, 1, 1)]


class StylePredictor(nn.Module):
    def __init__(self):
        super().__init__()
        self.stem = ConvBN(3, 32, 3, 2)
        blocks, cin = [], 32
        for t, c, n, s in MOBILENET_V2:
            for i in range(n):
                blocks.append(InvertedResidual(cin, c, s if i == 0 else 1, t))
                cin = c
        self.blocks = nn.Sequential(*blocks)
        self.head = ConvBN(cin, 1280)
        self.bottleneck = nn.Conv2d(1280, BOTTLENECK_DIM, 1)

    def forward(self, style):
        x = self.head(self.blocks(self.stem(style)))
        return self.bottleneck(x.mean(dim=(2, 3), keepdim=True))


class ConditionalInstanceNorm(nn.Module):
    """Instance norm with per-channel gamma and beta computed from the style bottleneck."""

    def __init__(self, channels):
        super().__init__()
        self.gamma = nn.Conv2d(BOTTLENECK_DIM, channels, 1)
        self.beta = nn.Conv2d(BOTTLENECK_DIM, channels, 1)
        self.eps = 1e-5

    def forward(self, x, style):
        return F.instance_norm(x, eps=self.eps) * self.gamma(style) + self.beta(style)


class ConvCIN(nn.Module):
    def __init__(self, cin, cout, k, padding_mode, upsample=None):
        super().__init__()
        if upsample is None:
            self.upsample = nn.Identity()
        else:
            self.upsample = nn.Upsample(scale_factor=2.0, mode=upsample,
                                        align_corners=False if upsample == "bilinear" else None)
        self.conv = nn.Conv2d(cin, cout, k, 1, k // 2, bias=False, padding_mode=padding_mode)
        self.norm = ConditionalInstanceNorm(cout)

    def forward(self, x, style):
        return self.norm(self.conv(self.upsample(x)), style)


class Blur(nn.Module):
    def __init__(self, channels):
        super().__init__()
        k = torch.tensor([1.0, 2.0, 1.0])
        kernel = (torch.outer(k, k) / 16).expand(channels, 1, 3, 3).contiguous()
        self.register_buffer("kernel", kernel, persistent=False)

    def forward(self, x):
        return F.conv2d(F.pad(x, (1, 1, 1, 1), mode="replicate"), self.kernel, groups=self.kernel.shape[0])


class ContractConv(nn.Module):
    def __init__(self, cin, cout, k, stride, padding_mode, antialias=False):
        super().__init__()
        # Blurring the input of the strided conv equals blurring its stride-1 output before
        # subsampling, so the pretrained kernels keep their meaning at no extra conv cost.
        self.blur = Blur(cin) if antialias and stride > 1 else nn.Identity()
        self.conv = nn.Conv2d(cin, cout, k, stride, k // 2, bias=False, padding_mode=padding_mode)
        self.bn = nn.BatchNorm2d(cout, eps=1e-3)

    def forward(self, x):
        return F.relu(self.bn(self.conv(self.blur(x))))


class ResidualBlock(nn.Module):
    def __init__(self, channels, padding_mode):
        super().__init__()
        self.conv1 = ConvCIN(channels, channels, 3, padding_mode)
        self.conv2 = ConvCIN(channels, channels, 3, padding_mode)

    def forward(self, x, style):
        return x + self.conv2(F.relu(self.conv1(x, style)), style)


class StyleTransformer(nn.Module):
    """padding_mode 'zeros' matches the TF.js graph (op Pad, no MirrorPad) and leaves a dark
    border; 'replicate' removes it."""

    def __init__(self, padding_mode="zeros", antialias=False):
        super().__init__()
        self.padding_mode, self.antialias = padding_mode, antialias
        pm = padding_mode
        up = "bilinear" if antialias else "nearest"
        self.contract = nn.Sequential(
            ContractConv(3, 32, 9, 1, pm),
            ContractConv(32, 64, 3, 2, pm, antialias),
            ContractConv(64, 128, 3, 2, pm, antialias),
        )
        self.residual = nn.ModuleList([ResidualBlock(128, pm) for _ in range(5)])
        self.expand = nn.ModuleList([
            ConvCIN(128, 64, 3, pm, upsample=up),
            ConvCIN(64, 32, 3, pm, upsample=up),
            ConvCIN(32, 3, 9, pm),
        ])

    def norm_layers(self):
        layers = [c.norm for b in self.residual for c in (b.conv1, b.conv2)]
        return layers + [layer.norm for layer in self.expand]

    def forward(self, content, style):
        x = self.contract(content)
        for block in self.residual:
            x = block(x, style)
        x = F.relu(self.expand[0](x, style))
        x = F.relu(self.expand[1](x, style))
        return torch.sigmoid(self.expand[2](x, style))


def load_checkpoint(path):
    """A transformer saved by train_stable.py."""
    ckpt = torch.load(path, map_location="cpu")
    m = StyleTransformer(ckpt["padding"], ckpt["antialias"])
    m.load_state_dict(ckpt["transformer"])
    return m.eval()
