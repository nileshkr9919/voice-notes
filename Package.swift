// swift-tools-version:5.10
// 5.10 tools keep the Swift 5 language mode by default, and work with both
// single-arch and universal (--arch arm64 --arch x86_64) builds on Xcode 16+.
import PackageDescription

let package = Package(
    name: "VoiceNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceNotes",
            path: "Sources/VoiceNotes"
        ),
        .testTarget(
            name: "VoiceNotesTests",
            dependencies: ["VoiceNotes"],
            path: "Tests/VoiceNotesTests"
        ),
    ]
)
