// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "airlift",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "AirliftRouting",
            path: "Sources/AirliftRouting",
            cSettings: [
                // Hand-rolled objc_msgSend calls to init-family selectors are
                // incompatible with ARC's retain/release bookkeeping.
                .unsafeFlags(["-fno-objc-arc"])
            ]
        ),
        .executableTarget(
            name: "airlift",
            dependencies: ["AirliftRouting"],
            path: "Sources/airlift"
        ),
    ]
)
