// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Python is linked only when scripts/fetch-python.sh has put CPython in Vendor/Python
// (docs/DESIGN.md, 6.4). Without it, everything builds and Python slots pause.
let pythonFramework = Context.packageDirectory + "/Vendor/Python/Python.xcframework"
let hasPython = FileManager.default.fileExists(atPath: pythonFramework)

var scriptDependencies: [Target.Dependency] = ["FutureEngine", "CLua"]
var pythonTargets: [Target] = []
if hasPython {
    scriptDependencies.append("CPythonBridge")
    pythonTargets = [
        .binaryTarget(name: "Python", path: "Vendor/Python/Python.xcframework"),
        // The app's bridge to CPython: starting it, audit hooks, time limits.
        .target(name: "CPythonBridge", dependencies: ["Python"]),
    ]
}

let package = Package(
    name: "EditTheFuture",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "FutureEngine", targets: ["FutureEngine"]),
        .library(name: "FutureFormula", targets: ["FutureFormula"]),
        .library(name: "FutureScript", targets: ["FutureScript"]),
        .library(name: "FutureCommands", targets: ["FutureCommands"]),
        .library(name: "FutureUI", targets: ["FutureUI"]),
        .executable(name: "EditTheFutureMac", targets: ["EditTheFutureMac"]),
        .executable(name: "etf-script", targets: ["etf-script"]),
    ],
    targets: [
        .target(name: "FutureEngine"),
        .target(name: "FutureFormula", dependencies: ["FutureEngine"]),
        // Lua 5.5, without its os, io, package and debug libraries.
        .target(name: "CLua", cSettings: [.headerSearchPath("lua")]),
        .target(name: "FutureScript", dependencies: scriptDependencies),
        .target(name: "FutureCommands"),
        .target(name: "FutureUI", dependencies: ["FutureEngine", "FutureFormula", "FutureScript", "FutureCommands"]),
        .executableTarget(name: "EditTheFutureMac", dependencies: ["FutureUI", "FutureCommands", "FutureEngine", "FutureScript"]),
        // Runs a script model without the app: swift run etf-script <file>
        .executableTarget(name: "etf-script", dependencies: ["FutureScript", "FutureEngine"]),
        // Performance benchmarks: swift run -c release etf-bench
        .executableTarget(name: "etf-bench", dependencies: ["FutureUI", "FutureFormula", "FutureEngine"]),
        .testTarget(name: "FutureEngineTests", dependencies: ["FutureEngine"]),
        .testTarget(name: "FutureFormulaTests", dependencies: ["FutureFormula", "FutureEngine"]),
        .testTarget(name: "FutureScriptTests", dependencies: ["FutureScript", "FutureEngine"]),
        .testTarget(name: "FutureCommandsTests", dependencies: ["FutureCommands"]),
        .testTarget(name: "FutureUITests", dependencies: ["FutureUI", "FutureEngine", "FutureFormula", "FutureScript", "FutureCommands"]),
    ] + pythonTargets
)
