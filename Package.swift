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
        .library(name: "FutureDocument", targets: ["FutureDocument"]),
        .library(name: "FutureFeeds", targets: ["FutureFeeds"]),
        .library(name: "FutureSimulation", targets: ["FutureSimulation"]),
        .library(name: "FutureVisuals", targets: ["FutureVisuals"]),
        .library(name: "FutureKit", targets: ["FutureKit"]),
        .library(name: "FutureFiles", targets: ["FutureFiles"]),
        .library(name: "FutureUI", targets: ["FutureUI"]),
        .executable(name: "EditTheFutureMac", targets: ["EditTheFutureMac"]),
        .executable(name: "etf-script", targets: ["etf-script"]),
        .executable(name: "etf-feed", targets: ["etf-feed"]),
        .executable(name: "etf", targets: ["etf"]),
    ],
    targets: [
        .target(name: "FutureEngine"),
        .target(name: "FutureFormula", dependencies: ["FutureEngine"]),
        // Lua 5.5, without its os, io, package and debug libraries.
        .target(name: "CLua", cSettings: [.headerSearchPath("lua")]),
        .target(name: "FutureScript", dependencies: scriptDependencies),
        .target(name: "FutureCommands"),
        // Saved scenarios: scenario.md, readings and the cache (docs/DESIGN.md, 15).
        .target(name: "FutureDocument", dependencies: ["FutureEngine"], linkerSettings: [.linkedLibrary("sqlite3")]),
        // Readings fetched from public sources, and the sign-ins they need (docs/DESIGN.md, 15.5).
        .target(name: "FutureFeeds", dependencies: ["FutureEngine", "FutureDocument"]),
        // What simulations written in Swift are built against (docs/DESIGN.md, 6.5). It, and each module,
        // sees only the engine: no UI, files or network. The app hands modules the data they need.
        .target(name: "FutureSimulation", dependencies: ["FutureEngine"]),
        // Each module has a folder of its own under Sources/Simulations.
        .target(name: "EpidemicSimulation", dependencies: ["FutureSimulation", "FutureEngine"], path: "Sources/Simulations/Epidemic"),
        .target(name: "WorldEpidemicSimulation", dependencies: ["FutureSimulation", "FutureEngine"],
                path: "Sources/Simulations/WorldEpidemic"),
        .target(name: "WormSimulation", dependencies: ["FutureSimulation", "FutureEngine"], path: "Sources/Simulations/Worm"),
        // The modules that come with the app.
        .target(name: "SimulationCatalog", dependencies: ["FutureSimulation", "EpidemicSimulation", "WorldEpidemicSimulation",
                                                          "WormSimulation"],
                path: "Sources/Simulations/Catalog"),
        // What backdrops show, such as the world's countries and the bright stars, without drawing them (docs/DESIGN.md, 9.6).
        .target(name: "FutureVisuals", dependencies: ["FutureEngine"]),
        // A scenario to run, edit and read, for the app or any app that embeds it (docs/DESIGN.md, 2.1).
        // It owns the engine's thread and undo, and draws nothing: no SwiftUI, AppKit or UIKit.
        .target(name: "FutureKit", dependencies: ["FutureEngine", "FutureFormula", "FutureScript", "FutureCommands", "FutureDocument",
                                                  "FutureFeeds", "FutureSimulation", "SimulationCatalog", "FutureVisuals"]),
        // Scenarios kept as .etf folders, with their feeds and exchange rates kept up to date. Optional for apps that embed FutureKit.
        .target(name: "FutureFiles", dependencies: ["FutureKit", "FutureEngine", "FutureDocument", "FutureFeeds", "FutureScript",
                                                    "FutureSimulation"]),
        // The views: the graph, the editing panes and the whole panel, and the backdrops drawn behind the graph.
        .target(name: "FutureUI", dependencies: ["FutureKit", "FutureEngine", "FutureFormula", "FutureScript", "FutureDocument",
                                                 "FutureFeeds", "FutureSimulation", "FutureVisuals"]),
        // The compiler records the App Intents' constant values, which scripts/build-app.sh turns into
        // the app's Metadata.appintents, as Xcode would, so Shortcuts, Siri and Spotlight find them.
        .executableTarget(name: "EditTheFutureMac", dependencies: ["FutureUI", "FutureKit", "FutureFiles", "FutureCommands", "FutureEngine", "FutureScript",
                                                                    "FutureDocument", "FutureFeeds"],
                          swiftSettings: [.unsafeFlags(["-emit-const-values", "-Xfrontend", "-const-gather-protocols-file",
                                                        "-Xfrontend", Context.packageDirectory + "/scripts/appintents-protocols.json"])]),
        // The command-line tool that comes inside the app: etf value savings --at 2030 (docs/DESIGN.md, 10.2)
        .executableTarget(name: "etf", dependencies: ["FutureCommands"]),
        // Fetches a feed without the app: swift run etf-feed "[feed: fred, series: DGS10]"
        .executableTarget(name: "etf-feed", dependencies: ["FutureFeeds", "FutureDocument", "FutureEngine"]),
        // Runs a script model without the app: swift run etf-script <file>
        .executableTarget(name: "etf-script", dependencies: ["FutureScript", "FutureEngine"]),
        // Performance benchmarks: swift run -c release etf-bench
        .executableTarget(name: "etf-bench", dependencies: ["FutureUI", "FutureKit", "FutureFormula", "FutureEngine", "FutureSimulation",
                                                             "SimulationCatalog"]),
        .testTarget(name: "FutureEngineTests", dependencies: ["FutureEngine"]),
        .testTarget(name: "FutureFormulaTests", dependencies: ["FutureFormula", "FutureEngine"]),
        .testTarget(name: "FutureScriptTests", dependencies: ["FutureScript", "FutureEngine"]),
        .testTarget(name: "FutureCommandsTests", dependencies: ["FutureCommands"]),
        .testTarget(name: "FutureDocumentTests", dependencies: ["FutureDocument", "FutureEngine", "FutureFormula"],
                    linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "FutureFeedsTests", dependencies: ["FutureFeeds", "FutureDocument", "FutureEngine"]),
        .testTarget(name: "FutureSimulationTests", dependencies: ["FutureSimulation", "FutureEngine"]),
        .testTarget(name: "FutureVisualsTests", dependencies: ["FutureVisuals", "FutureEngine"]),
        // A module's tests see only the module, the contract and the engine, as the module does.
        .testTarget(name: "EpidemicSimulationTests", dependencies: ["EpidemicSimulation", "FutureSimulation", "FutureEngine"],
                    path: "Tests/Simulations/Epidemic"),
        .testTarget(name: "WorldEpidemicSimulationTests", dependencies: ["WorldEpidemicSimulation", "FutureSimulation", "FutureEngine"],
                    path: "Tests/Simulations/WorldEpidemic"),
        .testTarget(name: "WormSimulationTests", dependencies: ["WormSimulation", "FutureSimulation", "FutureEngine"],
                    path: "Tests/Simulations/Worm"),
        // Dates and scenarios the tests of FutureKit, FutureFiles and FutureUI share.
        .target(name: "FutureTestSupport", dependencies: ["FutureKit", "FutureEngine", "FutureDocument"], path: "Tests/Support"),
        .testTarget(name: "FutureKitTests", dependencies: ["FutureKit", "FutureTestSupport", "FutureEngine", "FutureFormula", "FutureScript", "FutureCommands",
                                                           "FutureDocument", "FutureFeeds", "FutureSimulation", "FutureVisuals"]),
        .testTarget(name: "FutureFilesTests", dependencies: ["FutureFiles", "FutureKit", "FutureTestSupport", "FutureEngine", "FutureDocument", "FutureFeeds"]),
        .testTarget(name: "FutureUITests", dependencies: ["FutureUI", "FutureKit", "FutureFiles", "FutureTestSupport", "FutureEngine",
                                                          "FutureFormula", "FutureSimulation", "FutureVisuals"]),
    ] + pythonTargets
)
