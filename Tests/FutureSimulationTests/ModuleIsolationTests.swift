import Foundation
import Testing

/// Simulation modules stay apart from the UI, files, the network and other processes (docs/DESIGN.md,
/// 6.5). SwiftPM alone doesn't ensure it: a target can import another of the package's modules it
/// doesn't depend on, once that module has been built. So this reads every module's source.
@Suite("Module isolation")
struct ModuleIsolationTests {
    /// What a module may import: Foundation for its types, the engine, the contract, and maths.
    static let allowedImports: Set<String> = ["Foundation", "FutureEngine", "FutureSimulation", "Accelerate", "simd"]

    /// Ways to reach outside: files, the network, settings, the environment, other processes and libraries.
    static let forbidden = ["FileManager", "FileHandle", "URLSession", "URLRequest", "Bundle.", "Data(contentsOf", "String(contentsOf",
                            "contentsOfFile", "fopen", "Process(", "UserDefaults", "ProcessInfo", "getenv", "dlopen", "NSWorkspace",
                            "NWConnection", "CFNetwork", "write(to:", "write(toFile:"]

    static let simulations = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Simulations")

    /// Each module's Swift files, by folder name. The catalog, which lists the modules, is apart.
    static func sources() throws -> [(module: String, file: URL)] {
        let folders = try FileManager.default.contentsOfDirectory(at: simulations, includingPropertiesForKeys: nil)
        return try folders.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .flatMap { folder -> [(String, URL)] in
                let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
                return files.map { (folder.lastPathComponent, $0) }
            }
            .sorted { $0.1.path < $1.1.path }
            .map { (module: $0.0, file: $0.1) }
    }

    static func imports(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let index = words.firstIndex(of: "import"),
                  words[..<index].allSatisfy({ $0.hasPrefix("@") || ["public", "internal", "private", "fileprivate", "package"].contains($0) })
            else { return nil }
            // `import struct FutureDocument.SlotFile` names its module after the kind of declaration.
            let kinds: Set<Substring> = ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"]
            guard let name = words[(index + 1)...].first(where: { !kinds.contains($0) }) else { return nil }
            return String(name).components(separatedBy: ".").first
        }
    }

    @Test("Modules import only Foundation, the engine, the contract and maths")
    func imports() throws {
        let sources = try Self.sources()
        #expect(sources.contains { $0.module == "Epidemic" })
        for (module, file) in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            // The catalog lists the modules, so it imports them too.
            let allowed = module == "Catalog"
                ? Self.allowedImports.union(Self.imports(in: text).filter { $0.hasSuffix("Simulation") })
                : Self.allowedImports
            for name in Self.imports(in: text) {
                #expect(allowed.contains(name), "\(file.lastPathComponent) in \(module) imports \(name)")
            }
        }
    }

    @Test("Modules don't reach files, the network, settings or other processes")
    func outsideWorld() throws {
        for (module, file) in try Self.sources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in Self.forbidden where text.contains(word) {
                Issue.record("\(file.lastPathComponent) in \(module) uses \(word)")
            }
        }
    }

    @Test("The check catches what it should")
    func checkWorks() {
        #expect(Self.imports(in: "import Foundation\n@testable import FutureUI\npublic import struct FutureDocument.SlotFile\n// import X")
                == ["Foundation", "FutureUI", "FutureDocument"])
        #expect(!Self.allowedImports.contains("FutureUI") && !Self.allowedImports.contains("FutureDocument"))
    }
}
