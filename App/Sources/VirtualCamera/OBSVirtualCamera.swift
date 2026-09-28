import Foundation

/// The camera extension that OBS Studio installs. Values from obs-studio's CMakePresets.json and
/// OBSCameraProviderSource.swift.
enum OBSVirtualCamera {
    static let deviceUID = "7626645E-4425-469E-9D8B-97E0FA59AC75"
    static let deviceName = "OBS Virtual Camera"
    static let downloadURL = URL(string: "https://obsproject.com/download")!
}
