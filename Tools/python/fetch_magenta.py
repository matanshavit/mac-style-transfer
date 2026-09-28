"""Download the TF.js checkpoints used by @magenta/image 0.2.1 into cache/.

Usage: uv run fetch_magenta.py
"""
import hashlib
import os
import sys
import urllib.request

BASE_URL = "https://storage.googleapis.com/magentadata/js/checkpoints/style/arbitrary"
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cache")

# Pinned so an upstream change cannot silently change the converted models.
SHA256 = {
    "predictor/tensorflowjs_model.pb": "1ec29feea8b5ee72e5215cedfb41d04cac75d3107e16db67fbeca4192ff9abc6",
    "predictor/weights_manifest.json": "4781b7c9a4e8efaab75d0124d3f38261427e33ba9b652a7c9712227135a1af24",
    "predictor/group1-shard1of3": "f1ec7ee668b807f5096577e2f792cae90427d1adbeec1f25ef505231963d0438",
    "predictor/group1-shard2of3": "f002340b9aa4d6b2bb2a503d9329ea75d3a5d07692a20b9f4eff3a7b3a91b620",
    "predictor/group1-shard3of3": "27a64dfb5c0cba35f409d840dfa18e0a68ff5787354fe84d053b07c1a3b2861b",
    "transformer/tensorflowjs_model.pb": "289fc262cef7a3da5346d56a99bded22cb479e19f2cc4af8218213438038687e",
    "transformer/weights_manifest.json": "a33994cb7a6d474407083f2e01e2108655e95a9b2c81a6527e7b76513182ae5b",
    "transformer/group1-shard1of2": "d1a7e5511765b5384e7ccdd0765954c1aff127bc6372533da5740347dd3dab6b",
    "transformer/group1-shard2of2": "b96885a5c98ec24862459003f5576d24bf8d3c1e6c1cf86e3b4d28190b14d015",
}


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main():
    for rel, want in SHA256.items():
        path = os.path.join(CACHE, rel)
        if os.path.exists(path) and sha256(path) == want:
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        print("downloading", rel)
        urllib.request.urlretrieve(f"{BASE_URL}/{rel}", path)
        got = sha256(path)
        if got != want:
            os.remove(path)
            sys.exit(f"{rel}: sha256 {got}, expected {want}")
    print("checkpoints ready in", CACHE)


if __name__ == "__main__":
    main()
