import Foundation
import StyleKit

func pushTest(uid: String, name: String?, seconds: Double) -> Int32 {
    let output = VirtualCameraOutput(deviceUID: uid, fallbackDeviceName: name)
    let deviceName: String
    switch output.connect() {
    case .connected(let connectedName):
        deviceName = connectedName
    case .error(let message):
        printError("Could not connect to the camera: \(message)")
        return EXIT_FAILURE
    case .notFound, .disconnected:
        let lookup = name.map { "UID \(uid) or name \"\($0)\"" } ?? "UID \(uid)"
        printError("No camera found with \(lookup). Install the StyleCam camera extension, or run 'stylecam-cli devices' to list cameras.")
        return EXIT_FAILURE
    }

    let frameRate = 30
    guard let pattern = TestPattern(width: 1280, height: 720) else {
        printError("Could not create test pattern buffers.")
        return EXIT_FAILURE
    }
    print("Pushing 1280x720 420v at \(frameRate) fps to \(deviceName) for \(seconds) s")

    let start = Date()
    var sent = 0
    var dropped = 0
    for index in 0..<Int(seconds * Double(frameRate)) {
        Thread.sleep(until: start + Double(index) / Double(frameRate))
        if let frame = pattern.makeFrame(index: index), output.send(frame) {
            sent += 1
        } else {
            dropped += 1
        }
        if (index + 1) % frameRate == 0 {
            print("\((index + 1) / frameRate)s: sent \(sent), dropped \(dropped), \(output.state.status)")
        }
    }
    output.disconnect()
    return EXIT_SUCCESS
}
