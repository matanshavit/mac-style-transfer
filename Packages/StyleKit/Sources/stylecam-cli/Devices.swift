import StyleKit

func printDevices() {
    let devices = CMIODeviceDirectory.devices()
    guard !devices.isEmpty else {
        print("No CMIO devices found.")
        return
    }
    for device in devices {
        print(device.name)
        print("  uid: \(device.uid)")
        for stream in device.streams {
            let direction = stream.direction.map { "\($0)" } ?? "unknown direction"
            let format = stream.format.map { "\($0.pixelFormatName) \($0.width)x\($0.height)" } ?? "no format"
            let name = stream.name.map { " \"\($0)\"" } ?? ""
            print("  stream \(stream.id)\(name): \(direction), \(format)")
        }
    }
}
