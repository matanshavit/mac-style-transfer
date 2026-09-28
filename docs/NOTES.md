# StyleCam notes

Short working notes: spec, decisions, and why. Numbers are in [MEASUREMENTS.md](MEASUREMENTS.md).

## Goal

A Mac app that applies painting styles to the webcam in real time and shows up as a camera ("StyleCam") in Zoom, Meet, FaceTime, and other apps. Smooth first, then pretty.

Earlier version: [webcam-style-transfer](https://github.com/matanshavit/webcam-style-transfer) (browser, TF.js, Magenta arbitrary style network).

## Architecture

```
Webcam -> AVCaptureSession (app)
       -> scale down (Metal)
       -> style network (Core ML, GPU or Neural Engine)
       -> upscale + blend + smooth (Metal)
       -> NV12 frame -> CMIO sink stream
Camera extension: sink stream -> source stream -> Zoom / Meet / FaceTime
```

- **The app does all the work.** The extension only passes frames through. No shipped project runs Core ML inside a camera extension, and a changed extension often needs a reboot. We change the app often and the extension rarely.
- **Hand-off** uses the CMIO sink stream (`CMIOStreamCopyBufferQueue` + `CMSimpleQueueEnqueue`), like OBS and ldenoue/cameraextension. IOSurface buffers cross processes without a copy.
- **Output** is 420v (NV12 video range, BT.601) at 1280x720, 30 fps. Some clients reject BGRA. Only the YCbCr matrix attachment is set.
- **The extension** shows a placeholder when no frames arrive, accepts one feeder at a time, pulls sink frames only while a call app watches, and paces them to the client's frame rate on a schedule.
- **OBS fallback (experimental).** Without a developer team our extension cannot be installed, so the app can feed OBS's camera instead. OBS's sink lets the last feeder take over, so StyleCam leaves it alone while the OBS app is open, and only feeds it while our camera runs. Facts in `RESEARCH.md`.

## Modules

| Path | What |
|---|---|
| `App/` | SwiftUI app: preview, style gallery, controls, menu bar, App Intents, installs the extension |
| `Extension/` | CMIO camera extension: sink to source, placeholder |
| `Shared/` | IDs shared by app and extension |
| `Packages/StyleKit/` | Capture, engines, Metal render, virtual camera output, CLI (`stylecam-cli`) |
| `Models/` | Core ML models (`.mlpackage`), compiled by Xcode |
| `Styles/` | Painting images and catalog |
| `Tools/python/` | Model conversion, training, and stability metrics |

## Decisions

1. **Core ML on the GPU or the Neural Engine.** Auto picks (see 7). MLX has no ANE access. Metal 4 ML is new and unproven here.
2. **Magenta arbitrary style network**, ported from the old app's TF.js weights. One model covers every painting and custom image. A style is a 100-number vector, so switching is instant. Strength blends that vector with the live frame's own vector.
3. **Run the network below output size** (960x540 by default) and upscale with detail from the full-res camera frame. At 720p the network costs about 283 GFLOP per frame.
4. **Motion-aware temporal smoothing in Metal.** Still areas blend with the previous frame; moving areas take the new one. No optical flow.
5. **XcodeGen** builds the Xcode project from `project.yml`. The `.xcodeproj` is not committed.
6. **Signing**: the team ID lives in `Config/Local.xcconfig` (gitignored). Without a team the app builds, runs, and can feed OBS, but the extension cannot be installed.
7. **Auto quality is the default.** Steps: 960x540 GPU, 960x540 ANE, 640x360 ANE, 480x270 ANE.
   - The budget is 75% of the camera frame interval (25 ms at 30 fps) on the p50 of admission-to-output time over 1.5 s. Fixed runs up to 69% never dropped a frame; output got uneven near 100%.
   - Over budget: one step down. From the GPU it goes back to the ANE step its trial passed from. The next step stays loaded, so a switch drops at most one frame.
   - Up needs a trial: the higher step runs on copies of the frames and must fit 90% of the budget. From the ANE the trial is always the GPU step, since it does not slow ANE output. Same-device ANE trials run only when the GPU is not allowed or backing off.
   - It starts on the ANE, so a busy GPU drops nothing at startup. A free GPU takes over in about 3 s.
   - Trials back off from 20 s to 160 s, per device.
   - On battery, in Low Power Mode, or when hot, it uses the ANE only (not checked on battery).
   - At most two engines stay loaded, plus a trial. An engine that fails to load, or fails 30 frames in a row, is skipped for good.
8. **Two networks, steady by default.** `classic` is the Magenta transformer. `steady` is the same network with anti-aliased down/upsampling, fine-tuned against flicker (`Tools/python/train_stable.py`). Same inputs and output, all four sizes shipped.
   - Steady cuts static flicker 2-2.6x on the same engine and costs 5-8% more GPU time, 18% more ANE time.
   - A size without a steady model, or a steady engine that fails, runs classic, so frames never stop.
   - Export: `cd Tools/python && uv run convert_coreml.py --checkpoint <ckpt.pt>`. How the shipped ones were made is in `Tools/python/README.md`.
9. **Later:** per-painting networks, optical-flow smoothing, and a keep-warm trick for the ANE (paced ANE frames run about 2x slower than back to back at 640x360).

## App

- One main window, a menu bar item, and Settings. Closing the window keeps the app running, so the virtual camera keeps working.
- **Camera lifecycle.** The camera runs only while the window is visible, a call app uses the virtual camera (the extension's `scsc` client-count property), or the output is OBS and OBS's camera is found. Otherwise it stops after 2 s and the light goes off.
- The app never asks for camera access by itself. The preview shows a button for it.
- Launch at login does not open the window, so the camera stays off (checked with a simulated login launch, not a real one).
- Quitting while a call app uses StyleCam asks first. With OBS it cannot tell.
- Custom styles come from a file, drag and drop, or an https link (50 MB, 30 s limits). They live in `~/Library/Application Support/StyleCam/Styles`.
- Shortcuts and Spotlight can set or toggle the style (App Intents).

## Debug hooks

Debug builds only. Launch arguments:

- `-StyleCamVideoFile <file.y4m>`: play the file at 30 fps, looping, instead of the camera. Needs an absolute path.
- `-StyleCamStyle <id>`, `-StyleCamShowStats YES`, `-StyleCamWindowSize 900x600`, `-StyleCamVirtualCameraOutput stylecam|obs`.
- `-StyleCamCameraAccess notDetermined|denied`: show that permission state without opening the camera.
- `-StyleCamSnapshot <file.png> [-StyleCamSnapshotDelay 5]`: write the window, the latest frame (`-frame.png`) and the main menu (`-menu.txt`), then quit. The toolbar and menus do not render in it.
- With any of them, saved settings are left alone.

```sh
open -n build/DerivedData/Build/Products/Debug/StyleCam.app --args \
  -StyleCamVideoFile "$PWD/clip.y4m" -StyleCamStyle starry_night -StyleCamSnapshot /tmp/ui.png -StyleCamSnapshotDelay 8
```

## Dev loop

- `make build`, then `make run-demo` to run on a video. See README.
- Most work happens in the app and `stylecam-cli`, with no extension reinstall.
- Extension changes: bump `CURRENT_PROJECT_VERSION`, reinstall from the app, and expect a reboot sometimes.
