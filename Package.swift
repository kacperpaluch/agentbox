// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Agentbox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkillboxCore", targets: ["SkillboxCore"]),
        .executable(name: "agentbox", targets: ["AgentboxCLI"]),
        .executable(name: "AgentboxApp", targets: ["AgentboxApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")
    ],
    targets: [
        .target(name: "SkillboxCore"),
        .executableTarget(name: "AgentboxCLI", dependencies: ["SkillboxCore"], path: "Sources/SkillboxCLI"),
        .executableTarget(name: "AgentboxApp", dependencies: ["SkillboxCore", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/SkillboxApp"),
        .testTarget(name: "SkillboxCoreTests", dependencies: ["SkillboxCore"], resources: [.copy("Fixtures")])
    ]
)
