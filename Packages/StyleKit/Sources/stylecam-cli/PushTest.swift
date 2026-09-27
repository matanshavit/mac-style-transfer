import Foundation
import StyleKit

func pushTest(uid: String, name: String?, seconds: Double) throws -> Int32 {
    let frameRate = 30
    guard let frameCount = Int(exactly: (seconds * Double(frameRate)).rounded()) else {
        throw Options.UsageError(description: "--seconds is too large")
    }
    guard frameCount > 0 else {
        throw Options.UsageError(description: "--seconds must be at least one frame (1/\(frameRate) s)")
    }

    let output = VirtualCameraOutput(deviceUID: uid, fallbackDeviceName: name, clientCountSelector: "scsc")
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

    guard let pattern = TestPattern(width: 1280, height: 720) else {
        printError("Could not create test pattern buffers.")
        return EXIT_FAILURE
    }
    print("Pushing 1280x720 420v at \(frameRate) fps to \(deviceName) for \(seconds) s")

    let start = Date()
    var sent = 0
    var dropped = 0
    for index in 0..<frameCount {
        Thread.sleep(until: start + Double(index) / Double(frameRate))
        if let frame = pattern.makeFrame(index: index), output.send(frame) {
            sent += 1
        } else {
            dropped += 1
        }
        if (index + 1) % frameRate == 0 {
            print("\((index + 1) / frameRate)s: sent \(sent), dropped \(dropped), \(describe(output.state))")
        }
    }
    let state = output.state
    output.disconnect()
    print("Done: sent \(sent) of \(frameCount), dropped \(dropped), \(describe(state))")

    guard case .connected = state.status else {
        printError("The camera connection ended during the test.")
        return EXIT_FAILURE
    }
    guard sent > 0 else {
        printError("The camera did not accept any frames.")
        return EXIT_FAILURE
    }
    return EXIT_SUCCESS
}

private func describe(_ state: VirtualCameraOutput.State) -> String {
    let clients = state.sourceClientCount.map { "\($0) camera clients" } ?? "camera clients unknown"
    return "\(state.status), \(clients)"
}
