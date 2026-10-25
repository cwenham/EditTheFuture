// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EditTheFuture",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "FutureEngine", targets: ["FutureEngine"]),
        .library(name: "FutureFormula", targets: ["FutureFormula"]),
        .library(name: "FutureCommands", targets: ["FutureCommands"]),
        .library(name: "FutureUI", targets: ["FutureUI"]),
        .executable(name: "EditTheFutureMac", targets: ["EditTheFutureMac"]),
    ],
    targets: [
        .target(name: "FutureEngine"),
        .target(name: "FutureFormula", dependencies: ["FutureEngine"]),
        .target(name: "FutureCommands"),
        .target(name: "FutureUI", dependencies: ["FutureEngine", "FutureFormula", "FutureCommands"]),
        .executableTarget(name: "EditTheFutureMac", dependencies: ["FutureUI", "FutureCommands", "FutureEngine"]),
        .testTarget(name: "FutureEngineTests", dependencies: ["FutureEngine"]),
        .testTarget(name: "FutureFormulaTests", dependencies: ["FutureFormula", "FutureEngine"]),
        .testTarget(name: "FutureCommandsTests", dependencies: ["FutureCommands"]),
        .testTarget(name: "FutureUITests", dependencies: ["FutureUI", "FutureEngine", "FutureCommands"]),
    ]
)
