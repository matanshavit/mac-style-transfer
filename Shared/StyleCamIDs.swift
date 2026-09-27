import CoreVideo
import Foundation

enum StyleCamIDs {
    static let extensionBundleID = "com.matanshavit.StyleCam.Extension"
    static let deviceName = "StyleCam"
    static let manufacturer = "StyleCam"
    static let model = "StyleCam Virtual Camera"
    static let deviceUID = "8F3C2A71-5B64-4E0D-9A1E-3C7B5D2F6A90"
    static let sourceStreamUID = "8F3C2A71-5B64-4E0D-9A1E-3C7B5D2F6A91"
    static let sinkStreamUID = "8F3C2A71-5B64-4E0D-9A1E-3C7B5D2F6A92"

    /// Device property holding the number of clients streaming from the camera, as a decimal string.
    /// The extension publishes it as `4cc_<selector>_glob_0000`; CMIO clients read it with this selector.
    static let sourceClientCountSelector = "scsc"
    static let sourceClientCountProperty = "4cc_\(sourceClientCountSelector)_glob_0000"
}

enum StyleCamVideo {
    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let frameRate: Int32 = 30
    static let pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
}
