// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PickerCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PickerCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "EmojiPicker",
            dependencies: ["PickerCore"]
        ),
        .testTarget(
            name: "PickerCoreTests",
            dependencies: ["PickerCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
