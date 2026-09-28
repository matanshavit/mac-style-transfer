"""Run the original TF.js graphs in TensorFlow next to the PyTorch port (zero padding) and print
the differences. Needs TensorFlow, which the main environment does not have:

    uv run --no-project --python 3.12 --with tensorflow --with torch==2.7.1 --with pillow optional/tf_reference.py
"""
import os
import sys

import numpy as np
import tensorflow as tf
import torch
from PIL import Image
from tensorflow.core.framework import graph_pb2

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)
from fetch_magenta import CACHE
from tfjs_weights import load_predictor, load_transformer, read_tfjs_weights

STYLES = os.path.join(TOOLS, "..", "..", "Styles")


def session(name):
    model_dir = os.path.join(CACHE, name)
    gd = graph_pb2.GraphDef()
    gd.ParseFromString(open(os.path.join(model_dir, "tensorflowjs_model.pb"), "rb").read())
    weights = read_tfjs_weights(model_dir)
    for node in gd.node:
        if node.op == "Const":
            node.attr["value"].tensor.CopyFrom(tf.make_tensor_proto(weights[node.name]))
    graph = tf.Graph()
    with graph.as_default():
        tf.compat.v1.import_graph_def(gd, name="")
    return tf.compat.v1.Session(graph=graph)


def image(name, size):
    img = Image.open(os.path.join(STYLES, name)).convert("RGB").resize(size, Image.BILINEAR)
    return (np.asarray(img, dtype=np.float32) / 255.0)[None]


def main():
    torch.set_grad_enabled(False)
    pred, trans = load_predictor(), load_transformer("zeros")
    ps, ts = session("predictor"), session("transformer")
    for content_size, style_size in [((640, 360), (320, 256)), ((333, 250), (256, 323))]:
        content, style = image("hay_wain.jpg", content_size), image("starry_night.jpg", style_size)
        tf_b = ps.run("mobilenet_conv/Conv/BiasAdd:0", {"Placeholder:0": style})
        tf_out = ts.run("transformer/expand/conv3/conv/Sigmoid:0", {"Placeholder:0": content, "Placeholder_1:0": tf_b})
        b = pred(torch.from_numpy(style).permute(0, 3, 1, 2))
        out = trans(torch.from_numpy(content).permute(0, 3, 1, 2), b).permute(0, 2, 3, 1).numpy()
        print(f"content {content_size} style {style_size}: "
              f"bottleneck max abs {np.abs(b.numpy().transpose(0, 2, 3, 1) - tf_b).max():.2e}, "
              f"stylized max abs {np.abs(out - tf_out).max():.2e}")


if __name__ == "__main__":
    main()
