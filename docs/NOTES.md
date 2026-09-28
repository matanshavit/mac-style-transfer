# StyleCam notes

Short working notes. Spec, decisions, and why.

## Goal

A Mac app that applies painting styles to the webcam in real time and shows up as a camera ("StyleCam") in Zoom, Meet, FaceTime, and other apps. Fast and smooth first, then pretty.

Earlier version: [webcam-style-transfer](https://github.com/matanshavit/webcam-style-transfer) (browser, TF.js, Magenta arbitrary style network, 17 paintings, custom style by URL).

## Architecture

```
Webcam -> AVCaptureSession (app)
       -> scale down (Metal)
       -> style network (Core ML, Neural Engine)
       -> upscale + blend + smooth (Metal)
       -> NV12 frame -> CMIO sink stream
Camera extension: sink stream -> source stream -> Zoom / Meet / FaceTime
```

- **The app does all the work.** The camera extension only passes frames through. Reasons: no shipped project runs Core ML inside a camera extension, and a changed extension often needs a reboot to reload. We change the app often and the extension rarely.
- **Frame hand-off** uses the CMIO sink stream (`CMIOStreamCopyBufferQueue` + `CMSimpleQueueEnqueue`), the same pattern as OBS and ldenoue/cameraextension. IOSurface-backed buffers cross processes without a copy.
- **Output format** is 420v (NV12 video range) at 1280x720, 30 fps. Some clients reject BGRA. Color attachments are kept minimal.
- **The extension shows a placeholder** when the app is not sending frames.
- **One feeder at a time.** The sink rejects a second client while one is streaming, so `stylecam-cli push-test` is rejected while the app is connected. The extension only pulls sink frames while a call app is watching.

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

1. **Core ML on the Neural Engine** for the network. MLX has no ANE access. Metal 4 ML is new and unproven here.
2. **Start with the Magenta arbitrary style network** (the one the old app used), ported to Core ML. One model covers all paintings and custom images. The style is a 100-number vector, so switching is instant.
3. **Run the network below output resolution** (for example 640x360) and upscale with an edge-aware filter guided by the full-res camera frame. At 720p the network costs about 283 GFLOP per frame, which is too tight.
4. **Temporal smoothing in Metal**: motion-aware blend with the previous output. Cheap, no optical flow needed. Optical flow (Vision) is a later option.
5. **XcodeGen** generates the Xcode project (`project.yml`). The `.xcodeproj` is not committed.
6. **Signing**: team ID lives in `Config/Local.xcconfig` (gitignored). Without a team, the app builds and runs locally (preview only), and the extension cannot be installed.
7. Later: smaller per-painting networks trained on this Mac (PyTorch MPS) with a stability loss, if they beat Magenta on speed or look.

## App

- One main window, a menu bar item and a Settings window. Closing the window keeps the app running, so the virtual camera keeps working. The Dock icon or the menu bar brings the window back.
- **Camera lifecycle.** The camera and the pipeline run only while the main window is visible (not closed, minimized, fully covered, or behind a locked screen) or the virtual camera has at least one client. Otherwise they stop after 2 s and the camera light goes off. The client count is the extension's `scsc` device property, which `VirtualCameraOutput` reads once a second while connected. The app stays connected to the sink all the time to read it; frames only flow while the pipeline runs.
- The app never asks for camera access by itself. The preview shows a button for it.
- The controls are a plain side column, not a SwiftUI inspector. The inspector's glass background does not render in snapshots, so it could not be checked.
- Settings are in UserDefaults. Custom styles are in `~/Library/Application Support/StyleCam/Styles`.
- Styles can be switched from Shortcuts and Spotlight (App Intents: Set StyleCam Style, Toggle StyleCam Style).

## Debug hooks

Debug builds only. Launch arguments:

- `-StyleCamVideoFile <file.y4m>` plays the file at 30 fps, looping, instead of the camera. No camera permission.
- `-StyleCamStyle <id>`, `-StyleCamShowStats YES`, `-StyleCamWindowSize 900x600`.
- `-StyleCamCameraAccess notDetermined|denied` shows that permission state and never opens the camera.
- `-StyleCamSnapshot <file.png> [-StyleCamSnapshotDelay 5]` writes the window to `<file>.png` and the latest output frame to `<file>-frame.png`, then quits. `cacheDisplay` cannot draw the video layer, so the latest frame is drawn in its place. It also cannot draw the glass toolbar (a blank capsule) or menus.
- With any of them, saved settings and the window frame are left alone, and the window counts as visible while it is open, even with the screen locked.

```sh
open -n build/DerivedData/Build/Products/Debug/StyleCam.app --args \
  -StyleCamVideoFile clip.y4m -StyleCamStyle starry_night -StyleCamSnapshot /tmp/ui.png -StyleCamSnapshotDelay 8
```

## Dev loop

- `make generate` then `make build`. See README.
- `make run-demo` runs the app on a video file instead of the camera.
- Most work happens in the app and `stylecam-cli`, with no extension reinstall.
- Extension changes: bump `CURRENT_PROJECT_VERSION`, reinstall from the app, and expect a reboot sometimes.
