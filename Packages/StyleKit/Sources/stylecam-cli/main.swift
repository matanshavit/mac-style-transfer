import Foundation
import StyleKit

let usage = """
stylecam-cli \(StyleKit.version)

  bench     --models <dir> --size WxH --mode gpu|ane|dual [--network classic|steady] [--iters N] [--inflight N]
  run       --models <dir> --styles <dir> --style <id or image> --input <file.y4m> --out <file.mp4>
            [--frames N] [--loop] [--fps 30] [--quality auto|fast|balanced|max] [--size WxH --mode gpu|ane|dual]
            [--network classic|steady]
            [--strength 0..1] [--smoothing 0..1] [--upsample bilinear|guided] [--detail x] [--preserve-colors]
            [--mask everything|background|person] [--segmentation fast|balanced] [--realtime] [--log-adaptive]
            [--codec h264|hevc] [--stills <dir>] [--still-frames a,b,c]
            --loop repeats the input up to --frames; --log-adaptive prints auto quality decisions and stats each second;
            --network defaults to classic; with steady, sizes without a steady model run classic
  styles    --styles <dir> --models <dir> [--json]
  devices   list CMIO video devices and their streams
  push-test --uid <uid> | --name <name> [--seconds <n>]
            push a moving 1280x720 420v test pattern at 30 fps into a virtual camera's sink stream,
            found by UID, else by name (for example --name "OBS Virtual Camera")
  version
"""

let commandLine = Array(CommandLine.arguments.dropFirst())
do {
    switch commandLine.first {
    case "bench": try await runBench(Arguments(commandLine.dropFirst(), flags: []))
    case "run": try await runPipeline(Arguments(commandLine.dropFirst(), flags: ["preserve-colors", "realtime", "loop", "log-adaptive"]))
    case "styles": try await listStyles(Arguments(commandLine.dropFirst(), flags: ["json"]))
    case "devices": printDevices()
    case "push-test": exit(try pushTest(Arguments(commandLine.dropFirst(), flags: [])))
    case "version", "--version": print("stylecam-cli \(StyleKit.version)")
    default:
        print(usage)
        exit(commandLine.isEmpty ? 0 : EX_USAGE)
    }
} catch let error as UsageError {
    printError("error: \(error)\n\n\(usage)")
    exit(EX_USAGE)
} catch {
    printError("error: \(error)")
    exit(1)
}
