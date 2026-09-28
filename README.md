# StyleCam

Real-time painting styles on your Mac webcam, as a camera you can pick in Zoom, Meet, FaceTime, and other apps.

## Build

Needs Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make generate   # creates StyleCam.xcodeproj from project.yml
make build      # builds the app without signing (preview only)
make run-demo   # runs that build on a video instead of the camera
make install    # signed build, copied to /Applications
```

`make run-demo` plays `data/video/Johnny_1280x720_60.y4m` by default. Pass `VIDEO=path/to/file.y4m` and optionally `STYLE=great_wave`.

To use the virtual camera you need a paid Apple Developer team, and the app must run from `/Applications` (`make install`). See [docs/NEEDS_INPUT.md](docs/NEEDS_INPUT.md).

## Docs

- [docs/NOTES.md](docs/NOTES.md): spec, architecture, decisions
- [docs/RESEARCH.md](docs/RESEARCH.md): sources
- [docs/NEEDS_INPUT.md](docs/NEEDS_INPUT.md): open items for the owner
