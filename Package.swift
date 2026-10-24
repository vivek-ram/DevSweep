// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "DevSweep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DevSweep", targets: ["DevSweep"]),
        .executable(name: "devsweep-cli", targets: ["devsweep-cli"]),
    ],
    targets: [
        .target(name: "DevSweepCore", swiftSettings: v5),
        .executableTarget(name: "DevSweep", dependencies: ["DevSweepCore"], swiftSettings: v5),
        .executableTarget(name: "devsweep-cli", dependencies: ["DevSweepCore"], swiftSettings: v5),
        .testTarget(name: "DevSweepCoreTests", dependencies: ["DevSweepCore"], swiftSettings: v5),
    ]
)
