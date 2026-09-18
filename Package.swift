// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeCaps",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodeCaps", targets: ["CodeCaps"]),
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
    ],
    targets: [
        .target(name: "QuotaCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "CodeCaps",
            dependencies: ["QuotaCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        .testTarget(name: "CodeCapsTests", dependencies: ["CodeCaps"]),
    ]
)
