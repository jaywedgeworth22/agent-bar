// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentBar", targets: ["AgentBar"]),
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
    ],
    targets: [
        .target(name: "QuotaCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "AgentBar",
            dependencies: ["QuotaCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        .testTarget(name: "AgentBarTests", dependencies: ["AgentBar"]),
    ]
)
