import Foundation
import StyleKit

let usage = """
    stylecam-cli \(StyleKit.version)

    Usage:
      stylecam-cli devices
      stylecam-cli push-test --uid <uid> [--name <fallback name>] [--seconds <n>]

    Commands:
      devices     List CMIO video devices and their streams.
      push-test   Push a moving 1280x720 420v test pattern at 30 fps into a virtual camera's sink stream.
    """

var arguments = CommandLine.arguments.dropFirst()
switch arguments.popFirst() {
case "devices":
    printDevices()
case "push-test":
    do {
        let options = try Options(Array(arguments), allowed: ["--uid", "--name", "--seconds"])
        exit(try pushTest(uid: try options.required("--uid"), name: options["--name"], seconds: try options.positiveNumber("--seconds") ?? 10))
    } catch {
        printError("\(error)\n\n\(usage)")
        exit(EX_USAGE)
    }
case "-h", "--help", "help", nil:
    print(usage)
case let command?:
    printError("Unknown command \(command)\n\n\(usage)")
    exit(EX_USAGE)
}
