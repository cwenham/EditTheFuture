import Foundation
import FutureDocument
import FutureEngine
import FutureKit

extension ScenarioMenuActions {
    /// The scenario menu for a folder of `.etf` scenarios (docs/DESIGN.md, 15.1): it lists the folder,
    /// and new scenarios and copies go there.
    public init(folder: URL, current: @escaping () -> ScenarioPackage?, save: @escaping () -> Void,
                open: @escaping (ScenarioPackage) -> Void, showInFinder: @escaping () -> Void,
                openOther: @escaping () -> Void) {
        self.init(
            scenarios: { ScenarioLibrary.menuEntries(current: current(), in: folder) },
            takenNames: { mode in
                guard mode == .edit, let open = current() else { return ScenarioLibrary.takenNames(in: folder) }
                // A renamed scenario's folder follows its name, so the names beside it are taken.
                return ScenarioLibrary.takenNames(in: open.url.deletingLastPathComponent(), except: open)
            },
            current: current, save: save, open: open, showInFinder: showInFinder, openOther: openOther,
            make: { scenario, source in
                if let source {
                    return try ScenarioLibrary.duplicate(source, name: scenario.name, start: scenario.start, currency: scenario.currency,
                                                         rates: scenario.rates, numbers: scenario.numbers, in: folder)
                }
                return try ScenarioLibrary.createBlank(name: scenario.name, start: scenario.start, currency: scenario.currency,
                                                       rates: scenario.rates, numbers: scenario.numbers, in: folder)
            },
            folder: folder)
    }
}

extension ScenarioLibrary {
    /// Where a scenario called `name` goes in a folder.
    public static func package(named name: String, in folder: URL) -> ScenarioPackage {
        ScenarioPackage(url: folder.appendingPathComponent(ScenarioPackage.folderName(for: name), isDirectory: true)
            .appendingPathExtension(ScenarioPackage.fileExtension))
    }

    /// The names of the scenario folders in a folder, lowercased.
    public static func takenNames(in folder: URL, except: ScenarioPackage? = nil) -> Set<String> {
        Set(scenarios(in: folder).filter { $0 != except }.map { $0.name.lowercased() })
    }

    /// What the scenario menu lists: the scenarios in the folder, and the open one wherever it
    /// is, in Finder's order.
    public static func menuEntries(current: ScenarioPackage?, in folder: URL) -> [ScenarioPackage] {
        var list = scenarios(in: folder)
        if let current, !list.contains(current) { list.append(current) }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A new scenario: one blank formula, to start from. `currency` nil leaves it unsaid: US dollars.
    public static func blank(name: String, start: Date, currency: Currency? = nil, rates: ExchangeRateSource? = nil,
                             numbers: NumberStyle? = nil) -> ScenarioDefinition {
        let template = ModelLibrary.blankFormula
        var slot = SlotSpec(name: template.slotName, model: template.slotModelName, kind: template.kind,
                            formula: template.formula, variable: template.variable, format: template.format, position: 0)
        slot.showsInFile = false  // the model's own choice, so the heading stays plain
        return ScenarioDefinition(name: name, start: start, currency: currency, rates: rates, numbers: numbers, slots: [slot])
    }

    /// Writes a new scenario with one blank formula, and returns its folder.
    public static func createBlank(name: String, start: Date, currency: Currency? = nil, rates: ExchangeRateSource? = nil,
                                   numbers: NumberStyle? = nil, in folder: URL) throws -> ScenarioPackage {
        let package = package(named: name, in: folder)
        guard !FileManager.default.fileExists(atPath: package.url.path) else { throw CocoaError(.fileWriteFileExists) }
        try ScenarioDocument.create(blank(name: name, start: start, currency: currency, rates: rates, numbers: numbers), at: package)
        return package
    }

    /// Copies a scenario's folder under a new name, start and currency, with its readings but not
    /// its cache, and returns the copy.
    public static func duplicate(_ source: ScenarioPackage, name: String, start: Date, currency: Currency? = nil,
                                 rates: ExchangeRateSource? = nil, numbers: NumberStyle? = nil,
                                 in folder: URL) throws -> ScenarioPackage {
        let manager = FileManager.default
        let package = package(named: name, in: folder)
        guard !manager.fileExists(atPath: package.url.path) else { throw CocoaError(.fileWriteFileExists) }
        let parsed = try ScenarioFormat.parse(try source.readText())
        var file = parsed.file
        file.name = name
        file.start = start
        // The copy's file says its currency only when the original did, or it's another one.
        if let currency, currency != (file.currency ?? .usd) || file.currency != nil { file.currency = currency }
        file.rates = rates
        file.numbers = numbers
        do {
            try manager.createDirectory(at: package.url, withIntermediateDirectories: true)
            for item in try manager.contentsOfDirectory(at: source.url, includingPropertiesForKeys: nil)
            where item.lastPathComponent != source.cacheFolder.lastPathComponent {
                try manager.copyItem(at: item, to: package.url.appendingPathComponent(item.lastPathComponent))
            }
            try package.write(text: ScenarioFormat.text(for: file, over: parsed))
        } catch {
            try? manager.removeItem(at: package.url)
            throw error
        }
        return package
    }
}
