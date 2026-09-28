# Measurements

M5 Pro, macOS 26.6, nothing else running unless noted. Commands are `stylecam-cli` (build with `make cli`).

## Engine speed

`bench`, median of 300 predictions. GPU and ANE have one frame in flight, dual two.

| Size | GPU ms, classic / steady | ANE ms, classic / steady | Dual fps, classic / steady |
|---|---|---|---|
| 480x270 | 3.46 / 3.64 | 3.90 / 4.61 | 535 / 481 |
| 640x360 | 5.69 / 5.96 | 6.69 / 7.86 | 317 / 284 |
| 960x540 | 12.53 / 13.38 | 15.02 / 17.86 | 139 / 121 |
| 1280x720 | 22.32 / 24.09 | 26.35 / 31.32 | 76.5 / 66.5 |

Paced at 30 fps on an idle Mac the ANE is slower: 640x360 takes 13.0 / 14.3 ms instead of 6.7 / 7.9, and 960x540 17.9 / 19.5 instead of 15.0 / 17.9. The GPU barely changes. With the GPU busy, paced ANE runs at its back-to-back speed.

## Real time

`run --realtime --fps 30`, 20 s, starry_night, smoothing 0.8. Flicker and change are mean luma levels per frame. The input's moving change is 11.0 (Johnny) and 14.9 (KristenAndSara). No run dropped a frame.

| Run | Latency p50 ms | Static flicker | Moving change |
|---|---|---|---|
| auto classic (960x540 GPU after 2.5 s), Johnny / KristenAndSara | 15.7 / 15.6 | 1.71 / 1.39 | 14.8 / 20.3 |
| auto steady (960x540 GPU after 2.6-3.3 s), Johnny / KristenAndSara | 16.5 / 16.4 | 0.66 / 0.68 | 12.6 / 17.5 |
| 960x540 GPU, classic / steady | 15.6 / 16.5 | 1.71 / 0.66 | 14.8 / 12.7 |
| 960x540 ANE, classic / steady | 21.7 / 23.1 | 1.70 / 0.66 | 14.7 / 12.6 |
| 640x360 ANE, classic / steady | 16.7 / 17.8 | 1.40 / 0.54 | 11.0 / 9.5 |

## Auto under load

GPU load is a second process running `bench --size 1280x720 --mode gpu`. ANE load is the same with `--mode ane`.

- **GPU busy:** both networks hold 960x540 ANE for 30 s with no drops. GPU trials take 31-35 ms against the 22.5 ms limit. When the load stops, the next trial passes and auto is on the GPU within 25 s.
- **GPU and ANE busy:** steady reaches 480x270 ANE in 3.6 s (14 drops, all in the first 4 s), then steps back up on the ANE as the ANE load ends.
- **GPU load on and off with the ANE busy:** auto goes straight from the GPU back to 480x270 ANE with 1 drop.
- **60 fps, idle:** 19 drops in the first 2 s, then 640x360 ANE holds with no more drops.
- **Budget study**, fixed quality, 30 s, admission-to-output p50 / p95 ms, then output interval p95 / max ms:

  | Step | Classic, idle | Steady, idle | Classic, GPU load | Steady, GPU load |
  |---|---|---|---|---|
  | 960x540 GPU | 15.3 / 16.5, 34 / 44 | 16.1 / 17.0, 34 / 35 | 30.4 / 33.2, 39 / 46 | 33.4 / 41.6, 39 / 47 |
  | 960x540 ANE | 21.4 / 22.5, 35 / 37 | 22.9 / 24.1, 35 / 36 | 17.2 / 18.6, 35 / 35 | 20.1 / 21.5, 35 / 36 |
  | 640x360 ANE | 16.4 / 17.6, 35 / 39 | 17.5 / 19.1, 35 / 39 | 8.2 / 9.1, 34 / 36 | 9.4 / 10.1, 34 / 35 |

- **Heavy GPU load** (a PyTorch training job): the fixed 960x540 GPU preset dropped 41 of 301 frames at 53 ms latency, while auto held 30 fps on the ANE. That load also caused 50-150 ms stalls of our whole process every 15-45 s, which never happened on an idle Mac.

## Model accuracy

Core ML fp16 against the PyTorch port, per size: GPU 58.7-58.8 dB (max 1/255), ANE 54.1-54.3 dB (max 2/255). The PyTorch port matches TensorFlow running the original graph to 1/255. Details in `Tools/python/README.md`.
