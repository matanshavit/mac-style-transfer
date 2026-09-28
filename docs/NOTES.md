# StyleCam notes

Short working notes. Spec, decisions, and why.

## Goal

A Mac app that applies painting styles to the webcam in real time and shows up as a camera ("StyleCam") in Zoom, Meet, FaceTime, and other apps. Fast and smooth first, then pretty.

Earlier version: [webcam-style-transfer](https://github.com/matanshavit/webcam-style-transfer) (browser, TF.js, Magenta arbitrary style network, 17 paintings, custom style by URL).

## Architecture

```
Webcam -> AVCaptureSession (app)
       -> scale down (Metal)
       -> style network (Core ML, GPU or Neural Engine)
       -> upscale + blend + smooth (Metal)
       -> NV12 frame -> CMIO sink stream
Camera extension: sink stream -> source stream -> Zoom / Meet / FaceTime
```

- **The app does all the work.** The camera extension only passes frames through. Reasons: no shipped project runs Core ML inside a camera extension, and a changed extension often needs a reboot to reload. We change the app often and the extension rarely.
- **Frame hand-off** uses the CMIO sink stream (`CMIOStreamCopyBufferQueue` + `CMSimpleQueueEnqueue`), the same pattern as OBS and ldenoue/cameraextension. IOSurface-backed buffers cross processes without a copy.
- **Output format** is 420v (NV12 video range) at 1280x720, 30 fps. Some clients reject BGRA. Color attachments are kept minimal.
- **The extension shows a placeholder** when the app is not sending frames.
- **One feeder at a time.** The sink rejects a second client while one is streaming, so `stylecam-cli push-test` is rejected while the app is connected. The extension only pulls sink frames while a call app is watching.
- **OBS fallback (experimental).** Without a developer team our extension cannot be installed, so the app can feed OBS's camera extension instead (Virtual Camera > Output). Facts in `RESEARCH.md`. Frames go as they are (1280x720 420v), like OBS's own NV12 frames, though its sink declares BGRA 1920x1080. OBS's sink lets the last feeder take over, and stops for everyone when any feeder stops. So StyleCam leaves the sink alone while the OBS app is open (`NSWorkspace` launch and quit notifications), and only runs it while the camera runs, so OBS's placeholder shows otherwise. Its queue is drained whenever the sink runs, so a queue that stays full for 2 s means another feeder took the sink or stopped it, and we restart it. Two copies of StyleCam sending to OBS take it from each other every 2 s. The camera list hides OBS Virtual Camera, as it does StyleCam, to avoid a loop.

## Modules

| Path | What |
|---|---|
| `App/` | SwiftUI app: preview, style gallery, settings, menu bar, installs the extension |
| `Extension/` | CMIO camera extension: sink stream to source stream, placeholder |
| `Shared/` | IDs shared by app and extension |
| `Packages/StyleKit/` | Capture, style engine, Metal render, virtual camera output, CLI (`stylecam-cli`) |
| `Models/` | Compiled-by-Xcode Core ML models (`.mlpackage`) |
| `Styles/` | Painting images and catalog |
| `Tools/python/` | Model conversion and training scripts |

## Decisions

1. **Core ML, on the GPU or the Neural Engine** for the network (auto picks, see 8). MLX has no ANE access. Metal 4 ML is new and unproven here.
2. **Start with the Magenta arbitrary style network** (the one the old app used), ported to Core ML. One model covers all paintings and custom images. The style is a 100-number vector, so switching is instant.
3. **Run the network below output resolution** (for example 640x360) and upscale with an edge-aware filter guided by the full-res camera frame. At 720p the network costs about 283 GFLOP per frame, which is too tight.
4. **Temporal smoothing in Metal**: motion-aware blend with the previous output. Cheap, no optical flow needed. Optical flow (Vision) is a later option.
5. **XcodeGen** generates the Xcode project (`project.yml`). The `.xcodeproj` is not committed.
6. **Signing**: team ID lives in `Config/Local.xcconfig` (gitignored). Without a team, the app builds and runs locally and can feed OBS Virtual Camera (experimental), but the extension cannot be installed.
7. Later: smaller per-painting networks trained on this Mac (PyTorch MPS) with a stability loss, if they beat Magenta on speed or look.
8. **Auto quality is the default** (`Quality.auto`). Steps: 960x540 GPU, 960x540 ANE, 640x360 ANE, 480x270 ANE. 480x270 is the last resort for when the ANE is busy too: smooth comes before pretty. The budget is 75% of the camera frame interval (25 ms at 30 fps), checked on the p50 of admission-to-output time over 1.5 s. Over budget: go one step down. The next step down stays loaded, so the switch drops at most one frame.
   - Why 75%: fixed runs at up to 69% of the interval (steady 960x540 ANE, 22.9 ms) dropped nothing, with output interval p95 at 35 ms. Output only got uneven near 100% (960x540 GPU under a GPU load, 30-33 ms: output interval p95 39 ms, max 47 ms). At 65% steady left 960x540 ANE for no gain.
   - Going up needs a trial. The higher step runs on copies of the frames next to the step that feeds the output, and must fit 90% of the budget. A trial only starts once the current step fits its budget. From any ANE step the trial is 960x540 GPU, and a pass switches straight to it: a GPU trial does not hold up ANE output frames. Only while a failed GPU trial backs off does it try one ANE step up. That trial also needs the ANE to have time for both frames (estimated by pixel count), so it does not hold up output frames. At 60 fps that rules out ANE trials. Trials run at start, then 20 s after a step down or a failed trial, and back off to 160 s. The GPU and the ANE back off apart, so an ANE step down does not delay the GPU trial.
   - A trial slows the running step a little (a GPU trial delays our own GPU passes by about 2 ms). So there is no step down during a trial, and the 1.5 s window starts over after it.
   - It starts on the ANE and tries the GPU once the ANE step fits. A busy GPU drops nothing at startup. A free one takes over after the first window plus the trial, 2.5-3.3 s at 30 fps.
   - On battery, in Low Power Mode, or at thermal state serious or critical, it uses the ANE only.
   - At most two engines stay loaded, the running one and the next one (a switch target or the fallback), plus the trial while one runs. Engines that are not needed are unloaded.
   - A step whose engine fails to load, or fails 30 frames in a row, is skipped. There is no retry.
   - It only adapts in real-time runs (`.dropFrames`). Offline runs use the preferred step.
9. **Two networks, steady by default.** `classic` is the Magenta transformer (`MagentaTransformer_<W>x<H>`). `steady` is the same network, anti-aliased and fine-tuned against flicker by `Tools/python/train_stable.py` (`StableTransformer_<W>x<H>`). Same inputs and output. Both ship at all four sizes. Steady is the default because shimmer on a still background is the most visible fault in a call: on the same engine it cuts static flicker 2-2.6x. The app has a "Steady brushwork" switch in the Style section; the CLI defaults to classic so older numbers stay comparable.
   - Cost on an idle Mac (Measurements): 5-8% more GPU time and 18-19% more ANE time per frame. At 960x540 that is 0.9 ms on the GPU and 2.8 ms on the ANE.
   - With the old 65% budget (21.7 ms) that changed what auto picked. Paced steady 960x540 ANE takes 22.9 ms, so auto stepped down to 640x360 ANE and stayed there with the GPU free: trials went one step up, and the ANE has no time for both 640x360 and 960x540 in one interval. Now the budget is 25 ms and trials from the ANE go straight to the GPU (see 8), so steady reaches 960x540 GPU in 2.9-3.3 s (classic 2.5 s).
   - A size with no steady model, or whose steady engine fails, runs classic, so frames never stop. Auto steps over the sizes either network has. The stats engine row names the network and says when it fell back, for example `480x270 ane classic (no steady model)`.
   - Export the steady models from a checkpoint with `cd Tools/python && uv run convert_coreml.py --checkpoint <ckpt.pt>`. It writes `Models/StableTransformer_{480x270,640x360,960x540,1280x720}.mlpackage` (change with `--sizes`, `--out`, `--name`) and leaves the predictor alone. `make build` then bundles them. How the shipped ones were made is in `Tools/python/README.md`.

## Measurements

M5 Pro, macOS 26.6, nothing else running. The GPU numbers here before were measured with a PyTorch training job on the GPU; these replace them. What is left from that time is marked as under load.

`stylecam-cli bench`, median of 300 predictions. GPU and ANE have one frame in flight, dual two. Two rounds agreed within 0.1 ms.

| Size | GPU ms, classic / steady | ANE ms, classic / steady | Dual fps, classic / steady |
|---|---|---|---|
| 480x270 | 3.46 / 3.64 | 3.90 / 4.61 | 535 / 481 |
| 640x360 | 5.69 / 5.96 | 6.69 / 7.86 | 317 / 284 |
| 960x540 | 12.53 / 13.38 | 15.02 / 17.86 | 139 / 121 |
| 1280x720 | 22.32 / 24.09 | 26.35 / 31.32 | 76.5 / 66.5 |

`stylecam-cli run --realtime --fps 30`, 20 s, starry_night, smoothing 0.8. Static flicker and moving change are in levels; the input's moving change is 11.0 (Johnny) and 14.9 (KristenAndSara). No run dropped a frame. The longest output interval was 41 ms, except once 54 ms in auto steady on KristenAndSara, which two reruns did not repeat (36 and 39 ms).

| Run | Latency p50 ms | Static flicker | Moving change |
|---|---|---|---|
| auto classic, ends at 960x540 GPU after 2.5-2.6 s. Johnny / KristenAndSara | 15.7 / 15.6 | 1.71 / 1.39 | 14.8 / 20.3 |
| auto steady, ends at 960x540 GPU after 2.9-3.1 s. Johnny / KristenAndSara | 16.5 / 16.4 | 0.66 / 0.68 | 12.6 / 17.5 |
| 960x540 GPU, classic / steady, Johnny | 15.6 / 16.5 | 1.71 / 0.66 | 14.8 / 12.7 |
| 960x540 ANE, classic / steady, Johnny | 21.7 / 23.1 | 1.70 / 0.66 | 14.7 / 12.6 |
| 640x360 ANE, classic / steady, Johnny | 16.7 / 17.8 | 1.40 / 0.54 | 11.0 / 9.5 |

- Auto held 960x540 GPU for 60 s runs too, with no drops (steady switched at 3.3 s, classic at 2.5 s). The app showed `960x540 gpu steady`, `preferred` after 12 s.
- **Budget runs**, 30 s at fixed quality, Johnny. GPU load is a second process running `stylecam-cli bench --size 1280x720 --mode gpu --iters 100000`. Each cell is admission-to-output p50 / p95 ms, then output interval p95 / max ms. No run dropped a frame.

  | Step | Classic, idle | Steady, idle | Classic, GPU load | Steady, GPU load |
  |---|---|---|---|---|
  | 960x540 GPU | 15.3 / 16.5, 34 / 44 | 16.1 / 17.0, 34 / 35 | 30.4 / 33.2, 39 / 46 | 33.4 / 41.6, 39 / 47 |
  | 960x540 ANE | 21.4 / 22.5, 35 / 37 | 22.9 / 24.1, 35 / 36 | 17.2 / 18.6, 35 / 35 | 20.1 / 21.5, 35 / 36 |
  | 640x360 ANE | 16.4 / 17.6, 35 / 39 | 17.5 / 19.1, 35 / 39 | 8.2 / 9.1, 34 / 36 | 9.4 / 10.1, 34 / 35 |
- **Auto with that GPU load**: both networks hold 960x540 ANE for 30 s with no drops. The GPU trials at 2 s and 23 s take 32-35 ms against the 22.5 ms limit. With the load stopped 20 s in, the 23 s trial passes and auto is on 960x540 GPU at 24-25 s, no drops over 60 s.
- **Auto with GPU and ANE both loaded** (plus a 1280x720 ANE bench, stopped 15 s in), steady: 480x270 ANE at 3.6 s (14 drops, all in the first 4 s). GPU trials keep failing, so it steps up on the ANE instead: 640x360 at 24 s, 960x540 at 65 s.
- **Auto at 60 fps**, steady, idle: 960x540 ANE drops 19 frames in the first 2 s, then 640x360 ANE holds at 11.4 ms against 12.5 ms with no more drops (output interval max 22 ms). The GPU trial takes 16 ms against 11.2 ms.
- **ANE clock-down.** On an idle Mac, paced ANE is slower than back to back. At 30 fps, 640x360 takes 13.0 ms (classic) and 14.3 ms (steady) instead of 6.7 and 7.9, and 960x540 takes 17.9 and 19.5 instead of 15.0 and 17.9. The GPU barely changes: 960x540 takes 13.2 and 14.1 (bench 12.5 and 13.4). Under load, with the GPU busy, paced ANE ran at its back-to-back speed (640x360 7.0 ms at 10, 30 and 60 fps). So on battery, where auto uses the ANE only, both networks should hold 960x540 (21.4 and 22.9 ms against 25 ms). Not checked on battery. `specializationStrategy = .fastPrediction` changed nothing (within 3%). Extra ANE requests to keep it warm would only burn power. Not done.
- **Under load, GPU busy** (a PyTorch training job): `balanced` (960x540 GPU) ran 25.8 fps, 41 of 301 frames dropped, latency p50 53 ms. With the old 65% budget, auto held 960x540 ANE at 30 fps with classic (0-3 drops per 10 s), and steady stepped down to 640x360 in 3 of 4 runs.
- **Under load, ANE busy too** (plus a second process running 1280x720 on the ANE): 960x540 ANE and 640x360 ANE both take about 60 ms. Auto reaches 480x270 ANE in 3.4 s and holds there at 19 ms, 2 drops in 41 s.
- **Stalls under load.** With the training job, about once per 15-45 s every thread in our process stalled for 50-150 ms at the same time: Metal encode calls, Metal completion handlers, and the source timer. Our GPU and ANE work stayed fast. None on the idle Mac (260 s of real-time runs, longest output interval 41 ms), which fits kernel contention from the training job (29.6 GB wired) as the cause. Not verified further.

## App

- One main window, a menu bar item and a Settings window. Closing the window keeps the app running, so the virtual camera keeps working. The Dock icon or the menu bar brings the window back.
- **Camera lifecycle.** The camera and the pipeline run only while the main window is visible (not closed, minimized, fully covered, or behind a locked screen), the virtual camera has at least one client, or the output is OBS, its camera is found and the OBS app is not open. Otherwise they stop after 2 s and the camera light goes off. The client count is the extension's `scsc` device property, which `VirtualCameraOutput` reads once a second while connected. The app stays connected to StyleCam's sink all the time to read it; frames only flow while the pipeline runs. OBS's camera has no client count, so with OBS the camera stays on, and the UI says so.
- The app never asks for camera access by itself. The preview shows a button for it.
- If the camera sends no frame within 10 s, fails at runtime, or is interrupted by macOS, the preview says so instead of spinning.
- **Login launch.** macOS marks it with `keyAELaunchedAsLogInItem`, and SwiftUI then does not open the window, so the camera stays off. Checked with a simulated launch event (`NSWorkspace.OpenConfiguration.appleEvent`), not a real login. With OBS as the output, the camera turns on once StyleCam connects to OBS.
- Quitting while another app uses the virtual camera asks first. With OBS it cannot tell, so it does not ask.
- The controls are a plain side column, not a SwiftUI inspector. The inspector's glass background does not render in snapshots, so it could not be checked. The virtual camera section is at the top, because it is what makes the app useful in calls.
- Image links are fetched over https only (App Transport Security blocks http, so http links are upgraded). Limits: 50 MB, 30 s, and `text/`, `video/` or `audio/` responses are rejected before download.
- Settings are in UserDefaults. Custom styles are in `~/Library/Application Support/StyleCam/Styles`.
- Styles can be switched from Shortcuts and Spotlight (App Intents: Set StyleCam Style, Toggle StyleCam Style).

## Debug hooks

Debug builds only. Launch arguments:

- `-StyleCamVideoFile <file.y4m>` plays the file at 30 fps, looping, instead of the camera. No camera permission. The path must be absolute, because `open` starts the app in `/`.
- `-StyleCamStyle <id>`, `-StyleCamShowStats YES`, `-StyleCamWindowSize 900x600`, `-StyleCamVirtualCameraOutput stylecam|obs`.
- `-StyleCamCameraAccess notDetermined|denied` shows that permission state and never opens the camera.
- `-StyleCamSnapshot <file.png> [-StyleCamSnapshotDelay 5]` writes the window to `<file>.png`, the latest output frame to `<file>-frame.png` and the main menu (titles, shortcuts, checkmarks) to `<file>-menu.txt`, then quits. `cacheDisplay` cannot draw the video layer, so the latest frame is drawn in its place. It also cannot draw the glass toolbar (a blank capsule) or menus.
- With any of them, saved settings and the window frame are left alone, and the window counts as visible while it is open, even with the screen locked.

```sh
open -n build/DerivedData/Build/Products/Debug/StyleCam.app --args \
  -StyleCamVideoFile "$PWD/clip.y4m" -StyleCamStyle starry_night -StyleCamSnapshot /tmp/ui.png -StyleCamSnapshotDelay 8
```

## Dev loop

- `make generate` then `make build`. See README.
- `make run-demo` runs the app on a video file instead of the camera.
- Most work happens in the app and `stylecam-cli`, with no extension reinstall.
- Extension changes: bump `CURRENT_PROJECT_VERSION`, reinstall from the app, and expect a reboot sometimes.
