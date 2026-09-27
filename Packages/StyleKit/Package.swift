// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StyleKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StyleKit", targets: ["StyleKit"]),
        .executable(name: "stylecam-cli", targets: ["stylecam-cli"]),
    ],
    targets: [
        .target(name: "StyleKit"),
        .executableTarget(name: "stylecam-cli", dependencies: ["StyleKit"]),
    ]
)
