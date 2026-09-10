// swift-tools-version: 5.9
import PackageDescription

// Deliberately on tools-version 5.9: it defaults to the Swift 5 language mode.
// Swift 6 strict concurrency would demand Sendable annotations across every
// AppKit and ScreenCaptureKit boundary this app touches, which buys nothing for
// a single-process menu bar utility that already confines its state to @MainActor.
let package = Package(
    name: "Clamshell",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clamshell",
            path: "Sources/Clamshell"
        )
    ]
)
