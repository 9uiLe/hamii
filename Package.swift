// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "hamii",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HamiiCore", targets: ["HamiiCore"]),
        .library(name: "HamiiApplication", targets: ["HamiiApplication"]),
        .library(name: "HamiiFormat", targets: ["HamiiFormat"]),
        .library(name: "HamiiIndex", targets: ["HamiiIndex"]),
        .library(name: "HamiiGeneration", targets: ["HamiiGeneration"]),
        .library(name: "HamiiIntegration", targets: ["HamiiIntegration"]),
        .library(name: "HamiiIntegrationRuntime", targets: ["HamiiIntegrationRuntime"]),
        .library(name: "HamiiMigrations", targets: ["HamiiMigrations"]),
        .library(name: "HamiiPreviewProtocol", targets: ["HamiiPreviewProtocol"]),
        .library(name: "HamiiNativeRuntime", targets: ["HamiiNativeRuntime"]),
        .executable(name: "hamii", targets: ["HamiiCLI"]),
        .executable(name: "hamii-studio", targets: ["HamiiApp"])
    ],
    targets: [
        .target(name: "HamiiCore"),
        .target(name: "HamiiApplication", dependencies: ["HamiiCore"]),
        .target(name: "HamiiFormat", dependencies: ["HamiiCore", "HamiiApplication"]),
        .target(name: "HamiiIndex", dependencies: ["HamiiCore", "HamiiFormat"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "HamiiGeneration", dependencies: ["HamiiCore"]),
        .target(name: "HamiiIntegration", dependencies: ["HamiiCore"]),
        .target(name: "HamiiIntegrationRuntime", dependencies: ["HamiiCore", "HamiiApplication", "HamiiFormat", "HamiiIntegration"]),
        .target(name: "HamiiMigrations"),
        .target(name: "HamiiMigrationRuntime", dependencies: ["HamiiMigrations", "HamiiCore", "HamiiFormat", "HamiiIndex"]),
        .target(name: "HamiiPreviewProtocol", dependencies: ["HamiiCore"]),
        .target(name: "HamiiNativeRuntime", dependencies: ["HamiiCore", "HamiiPreviewProtocol"]),
        .executableTarget(name: "HamiiCLI", dependencies: ["HamiiCore", "HamiiApplication", "HamiiFormat", "HamiiIndex", "HamiiGeneration", "HamiiIntegration", "HamiiIntegrationRuntime", "HamiiMigrations", "HamiiMigrationRuntime"]),
        .executableTarget(name: "HamiiApp", dependencies: ["HamiiCore", "HamiiApplication", "HamiiFormat", "HamiiPreviewProtocol", "HamiiNativeRuntime"]),
        .testTarget(name: "HamiiTests", dependencies: ["HamiiCore", "HamiiApplication", "HamiiFormat", "HamiiIndex", "HamiiGeneration", "HamiiIntegration", "HamiiIntegrationRuntime", "HamiiMigrations", "HamiiMigrationRuntime", "HamiiPreviewProtocol", "HamiiNativeRuntime"])
    ]
)
