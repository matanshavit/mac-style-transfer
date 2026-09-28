# Research notes

Condensed. Links are the sources. Dates matter: checked 2026-09.

## Virtual camera

- DAL plugins stopped loading in macOS 14.1. Camera extensions (CMIOExtension) are the only way. [Eclectic Light](https://eclecticlight.co/2023/10/27/how-sonoma-14-1-could-stop-your-camera-working/)
- Needs a paid developer team. `system-extension.install` is a restricted entitlement and needs a profile. [Apple forum 710046](https://developer.apple.com/forums/thread/710046), [capability table](https://developer.apple.com/help/account/reference/supported-capabilities-macos)
- App must be in `/Applications` to activate the extension.
- Sink stream pattern: [OBS mac-virtualcam](https://github.com/obsproject/obs-studio/tree/master/plugins/mac-virtualcam/src/camera-extension), [ldenoue/cameraextension](https://github.com/ldenoue/cameraextension) (app side: `CMIOStreamCopyBufferQueue`, `CMSimpleQueueEnqueue`).
- `consumeSampleBuffer` returns at once on an empty queue. Poll with a timer (OBS uses 3x frame rate) or back off, or it burns a core.
- Publish 420v, not BGRA. WhatsApp and some clients reject BGRA. Use a frame duration range, not a fixed list. [aicamera #71](https://github.com/kortexa-ai/aicamera/issues/71)
- Restamp buffers with host time when forwarding. [Apple forum 725481](https://developer.apple.com/forums/thread/725481)
- Strip ICC and color space attachments on output. Clients rebuild a CGColorSpace per frame otherwise. [OpenLens #3](https://github.com/trsdn/OpenLens/issues/3), [OpenLens PR 15](https://github.com/trsdn/OpenLens/pull/15)
- No live replacement of a running extension. Updates often need a reboot. [aicamera #73](https://github.com/kortexa-ai/aicamera/issues/73), [The Offcuts part 1](https://theoffcuts.org/posts/core-media-io-camera-extensions-part-one/)
- Every real project with heavy processing does it in the app: aicamera, macos-cam-fx, OpenCamraHub. Hand-off cost at 1080p30 is about 11% of one core. [OpenCamraHub](https://github.com/trsdn/OpenCamraHub)
- XcodeGen system extension embed: `copy: {destination: plugins, subpath: ../Library/SystemExtensions}`. [dautovri/SimulatorCamera](https://github.com/dautovri/SimulatorCamera)

## OBS Virtual Camera

Read from obs-studio at 50530ce (2026-09). Not tested: OBS is not installed here.

- Device "OBS Virtual Camera" ([provider](https://github.com/obsproject/obs-studio/blob/50530ce9046599e698c5d2068e4f053fae2318f6/plugins/mac-virtualcam/src/camera-extension/OBSCameraProviderSource.swift#L22)), UID `7626645E-4425-469E-9D8B-97E0FA59AC75` in release builds ([CMakePresets](https://github.com/obsproject/obs-studio/blob/50530ce9046599e698c5d2068e4f053fae2318f6/CMakePresets.json#L97)). No custom properties, so no client count.
- Source and sink declare one format, BGRA 1920x1080 at 60 fps ([device](https://github.com/obsproject/obs-studio/blob/50530ce9046599e698c5d2068e4f053fae2318f6/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift#L53-L83)). Sink queue size 1, and `authorizedToStartStream` accepts any client ([sink](https://github.com/obsproject/obs-studio/blob/50530ce9046599e698c5d2068e4f053fae2318f6/plugins/mac-virtualcam/src/camera-extension/OBSCameraStreamSink.swift#L73-L92)).
- OBS itself never sends that format. It enqueues NV12 (or I420, UYVY, P010) at its output size, PTS = its frame time in host-clock ns, no duration, and does not check for a full queue ([plugin](https://github.com/obsproject/obs-studio/blob/50530ce9046599e698c5d2068e4f053fae2318f6/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm#L337-L365), [enqueue](https://github.com/obsproject/obs-studio/blob/50530ce9046599e698c5d2068e4f053fae2318f6/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm#L535-L541)). It takes the second stream as the sink ([plugin](https://github.com/obsproject/obs-studio/blob/50530ce9046599e698c5d2068e4f053fae2318f6/plugins/mac-virtualcam/src/obs-plugin/plugin-main.mm#L425-L437)).
- The extension forwards each buffer unchanged, stamped with its PTS as host time, and QuickTime and most clients follow the buffer size. Apps that force the declared size scale or crop ([device](https://github.com/obsproject/obs-studio/blob/50530ce9046599e698c5d2068e4f053fae2318f6/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift#L242-L272), [#10263](https://github.com/obsproject/obs-studio/issues/10263)). It drains the sink at 180 Hz while the sink runs, watched or not.
- Two feeders: the last one to start the sink wins (the old consume timer is replaced). When any feeder stops, the sink stops for all and the placeholder shows ([device](https://github.com/obsproject/obs-studio/blob/50530ce9046599e698c5d2068e4f053fae2318f6/plugins/mac-virtualcam/src/camera-extension/OBSCameraDeviceSource.swift#L274-L307)).

## Models

- Johnson and Magenta transformer nets cost about 154K MAC per pixel. 720p is about 283 GFLOP per frame, 8.5 TFLOPS at 30 fps.
- ANE runs instance norm natively on M1+. [arXiv 2606.22283](https://arxiv.org/abs/2606.22283) (reverse engineering, not Apple)
- Pretrained Johnson weights (jcjohnson, lengstrom) are research-use only and cover 3 of our paintings. Train our own if we want per-style nets.
- Create ML app dropped Style Transfer projects in Xcode 26. The `MLStyleTransfer` Swift API still exists. Trains at 512 px. [Xcode 26 notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
- We tried Create ML (`MLStyleTransfer`) on Starry Night. It trains on the CPU only, in about 3 min per style (13 min at textel density 512). The lite model is 0.6 MB and runs 720p in 6.9 ms on the ANE. But it looks like a mild filter, and shifts of 1-3 px reshuffle the texture: strong shimmer. The stride-4 downsampling aliases, and Create ML cannot train that out. Not used.
- Magenta arbitrary style (Apache-2.0). Old app weights: `storage.googleapis.com/magentadata/js/checkpoints/style/arbitrary/{predictor,transformer}`. No existing PyTorch port with these weights, so we wrote one.
- Flicker: Lai 2018 is an online network (ConvLSTM, no flow at test time). [paper](https://arxiv.org/abs/1808.00449), [code, MIT](https://github.com/phoenix104104/fast_blind_video_consistency). Gupta 2017: training with noise improves stability. [paper](https://arxiv.org/abs/1705.02092)

## Apple Silicon

- M5 GPU "Neural Accelerators" are reachable through Metal Performance Primitives and Metal 4 tensors. No evidence Core ML uses them for conv. [tzakharko](https://tzakharko.github.io/apple-neural-accelerators-benchmark/)
- Use fixed input shapes per resolution for clean ANE placement. Check placement with `MLComputePlan`.
- Vision person segmentation: we use `.balanced` at 30 fps. Its mask is as fresh as `.fast`'s (the current frame at balanced, the previous frame at fast) and has twice the resolution.
