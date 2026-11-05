// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeCompanion",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeCompanion",
            path: "Sources/ClaudeCompanion",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
