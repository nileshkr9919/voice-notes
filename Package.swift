// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoiceNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceNotes",
            path: "Sources/VoiceNotes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VoiceNotesTests",
            dependencies: ["VoiceNotes"],
            path: "Tests/VoiceNotesTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
