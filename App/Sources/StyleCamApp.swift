import SwiftUI

@main
struct StyleCamApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("StyleCam")
                VirtualCameraSettingsView()
            }
            .frame(minWidth: 640, minHeight: 400)
        }
    }
}
