// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ProSpeechBrain",
    platforms: [
        .iOS(.v17), .macOS(.v14)
    ],
    products: [
        .library(name: "ProSpeechBrain", targets: ["ProSpeechBrain"])
    ],
    targets: [
        .target(
            name: "ProSpeechBrain",
            path: "Sources/ProSpeechBrain"
        ),
        .testTarget(
            name: "ProSpeechBrainTests",
            dependencies: ["ProSpeechBrain"],
            path: "Tests/ProSpeechBrainTests"
        )
    ]
)
