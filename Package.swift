// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EditTheFuture",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "FutureEngine", targets: ["FutureEngine"]),
        .library(name: "FutureFormula", targets: ["FutureFormula"]),
        .library(name: "FutureCommands", targets: ["FutureCommands"]),
    ],
    targets: [
        .target(name: "FutureEngine"),
        .target(name: "FutureFormula", dependencies: ["FutureEngine"]),
        .target(name: "FutureCommands"),
        .testTarget(name: "FutureEngineTests", dependencies: ["FutureEngine"]),
        .testTarget(name: "FutureFormulaTests", dependencies: ["FutureFormula", "FutureEngine"]),
        .testTarget(name: "FutureCommandsTests", dependencies: ["FutureCommands"]),
    ]
)
