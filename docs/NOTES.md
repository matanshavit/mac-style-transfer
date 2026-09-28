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
8. **Auto quality is the default** (`Quality.auto`). Steps: 960x540 GPU, 960x540 ANE, 640x360 ANE, 480x270 ANE. 480x270 is the last resort for when the ANE is busy too: smooth comes before pretty. The budget is 65% of the camera frame interval (21.7 ms at 30 fps), checked on the p50 of admission-to-output time over 1.5 s. Over budget: go one step down. The next step down stays loaded, so the switch drops at most one frame.
   - Going up needs a trial. The higher step runs on copies of the frames next to the step that feeds the output, and must fit 90% of the budget. A trial only starts once the current step fits its budget. A trial on the ANE from a smaller ANE step also needs the ANE to have time for both frames (estimated by pixel count), so the trial does not hold up output frames. At 60 fps that rules out ANE trials. Trials run at start, then 20 s after a step down, and back off to 160 s.
   - A trial slows the running step a little (a GPU trial delays our own GPU passes by about 2 ms). So there is no step down during a trial, and the 1.5 s window starts over after it.
   - It starts on the ANE and tries the GPU once the ANE step fits. A busy GPU drops nothing at startup. A free one takes over after the first window plus the trial, about 2.5 s at 30 fps.
   - On battery, in Low Power Mode, or at thermal state serious or critical, it uses the ANE only.
   - At most two engines stay loaded, the running one and the next one (a switch target or the fallback), plus the trial while one runs. Engines that are not needed are unloaded.
   - A step whose engine fails to load, or fails 30 frames in a row, is skipped. There is no retry.
   - It only adapts in real-time runs (`.dropFrames`). Offline runs use the preferred step.
9. **Two networks, steady by default.** `classic` is the Magenta transformer (`MagentaTransformer_<W>x<H>`). `steady` is the same network, anti-aliased and fine-tuned against flicker by `Tools/python/train_stable.py` (`StableTransformer_<W>x<H>`). Same inputs and output. Steady is the default because shimmer on a still background is the most visible fault in a call, and it costs 1-3 ms of ANE time per frame. That puts 960x540 ANE at the edge of auto's budget (see Measurements). The app has a "Steady brushwork" switch in the Style section; the CLI defaults to classic so older numbers stay comparable.
   - No steady models are committed yet. Until they are exported (below), every build runs classic and the app's switch is off.
   - A size with no steady model, or whose steady engine fails, runs classic, so frames never stop. Auto steps over the sizes either network has. The stats engine row names the network and says when it fell back, for example `480x270 ane classic (no steady model)`.
   - Export the steady models from a checkpoint with `cd Tools/python && uv run convert_coreml.py --checkpoint <ckpt.pt>`. It writes `Models/StableTransformer_{480x270,640x360,960x540,1280x720}.mlpackage` (change with `--sizes`, `--out`, `--name`) and leaves the predictor alone. `make build` then bundles them.

## Measurements

- With a PyTorch training job on the GPU: `balanced` (960x540 GPU) runs 25.8 fps, 41 of 301 frames dropped, latency p50 53 ms. `auto` runs 960x540 ANE at 30 fps, latency p50 18.5 ms. It drops 0-3 frames per 10 s, the same as a fixed 960x540 ANE run.
- With the ANE busy too (a second process running 1280x720 on the ANE): 960x540 ANE and 640x360 ANE both take about 60 ms. Auto reaches 480x270 ANE in 3.4 s and holds there at 19 ms, 2 drops in 41 s.
- **ANE clock-down.** While the GPU is busy, paced ANE runs at its back-to-back speed: 640x360 takes 7.0 ms at 10, 30 and 60 fps, and 960x540 takes 15.7 ms. I could not reproduce the earlier 12.9 ms (about 2x) while the training job ran, so it likely needs an otherwise idle Mac. Auto uses the ANE when the GPU is busy (then the ANE is at full speed) or to save power (then being slower is OK). `specializationStrategy = .fastPrediction` changed nothing (within 3%). Extra ANE requests to keep it warm would only burn power. Not done. Not measured yet: 960x540 ANE paced on an idle Mac. If it is over budget, auto on battery ends up at 640x360.
- **Steady vs classic**, early test models at 640x360 and 960x540 (re-measure with the final ones). Johnny, 300 frames at 30 fps, 960x540, starry_night, offline: static flicker 1.69 to 0.68 levels with smoothing 0.8 (GPU and ANE alike), and 6.88 to 2.63 with smoothing off (GPU). Bench, ANE, one frame in flight: 640x360 6.7 to 7.9 ms, 960x540 15.4 to 18.3 ms. Auto under the training job, 30 s real-time runs: in the CLI, classic held 960x540 ANE in 4 of 4 runs (total p50 18-19.5 ms against the 21.7 ms budget) and steady stepped down to 640x360 in 3 of 4 (21-22.5 ms). Its trial back up took 20.3 ms against the 19.5 ms limit, so it stays at 640x360 while the GPU is busy. In the app, auto stepped down within 12 s with either network (classic 22.0 ms, steady 22.2-23.3 ms), and the classic trial back up took 20.1 ms.
- **Leftover stalls under the training job.** About once per 15-45 s, every thread in our process stalls for 50-150 ms at the same time: Metal encode calls, Metal completion handlers, and the source timer. Our GPU and ANE work stays fast, and command buffers wait less than 15 ms for the GPU. It also happens with fixed ANE settings. Likely cause: kernel contention from the training job, which has 29.6 GB wired. Not verified, not fixed.

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
