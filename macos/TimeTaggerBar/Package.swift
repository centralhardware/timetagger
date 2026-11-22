// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TimeTaggerBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TimeTaggerBar", path: "Sources/TimeTaggerBar"),
        // The background LaunchAgent that records which app is in front; ships inside the app bundle.
        .executableTarget(name: "TimeTaggerUsage", path: "Sources/TimeTaggerUsage"),
    ]
)
