// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DynamicNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NotchShared"),
        .executableTarget(
            name: "DynamicNotch",
            dependencies: ["NotchShared"],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("IOBluetooth")]
        ),
        .executableTarget(name: "notch", dependencies: ["NotchShared"]),
    ],
    swiftLanguageModes: [.v5]
)
