// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "DevSweep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DevSweep", targets: ["DevSweep"]),
        .executable(name: "devsweep-cli", targets: ["devsweep-cli"]),
        .executable(name: "DevSweepWidgets", targets: ["DevSweepWidgets"]),
    ],
    targets: [
        .target(name: "DevSweepCore", swiftSettings: v5),
        .executableTarget(name: "DevSweep", dependencies: ["DevSweepCore", "DevSweepWidgetUI"], swiftSettings: v5),
        .executableTarget(name: "devsweep-cli", dependencies: ["DevSweepCore"], swiftSettings: v5),
        // The desktop widgets; scripts/build-app.sh packs this into DevSweep.app as an app extension.
        .target(name: "DevSweepWidgetUI", dependencies: ["DevSweepCore"], swiftSettings: v5),
        // The desktop widgets; scripts/build-app.sh packs this into DevSweep.app as an app extension.
        // Like Xcode, it starts at Foundation's NSExtensionMain rather than main: entered at main,
        // WidgetKit sets up and returns, and the extension exits before macOS can talk to it.
        .executableTarget(name: "DevSweepWidgets", dependencies: ["DevSweepCore", "DevSweepWidgetUI"], swiftSettings: v5,
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(name: "DevSweepCoreTests", dependencies: ["DevSweepCore"], swiftSettings: v5),
    ]
)
