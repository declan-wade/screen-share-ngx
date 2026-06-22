// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "screenshare",
    platforms: [
        // ScreenCaptureKit needs 12.3+, but several conveniences (and the
        // hardware HEVC path through VideoToolbox) are cleanest on 13+.
        .macOS(.v13)
    ],
    products: [
        .executable(name: "screenshare", targets: ["screenshare"])
    ],
    dependencies: [
        // Community distribution of upstream libwebrtc binaries for Apple
        // platforms. Includes the VideoToolbox H.264/H.265 hardware encoders.
        .package(url: "https://github.com/stasel/WebRTC.git", .upToNextMajor(from: "149.0.0")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "screenshare",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            // -O for the release build is set via `swift build -c release`.
            swiftSettings: [
                .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))
            ]
        )
    ]
)
