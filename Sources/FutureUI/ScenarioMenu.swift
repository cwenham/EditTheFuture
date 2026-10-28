import Foundation
import FutureDocument
import FutureEngine

// The scenario menu in the panel's header, and its form (docs/UI.md, 3): switching scenarios,
// making new ones, and changing a scenario's name, start date and seed.

/// A scenario's name, start date and seed: what the heading of its `scenario.md` holds
/// (docs/DESIGN.md, 15.2).
public struct ScenarioSettings: Equatable, Sendable {
    public var name: String
    public var start: Date
    /// nil for the engine's own (docs/DESIGN.md, 4.4).
    public var seed: UInt64?

    public init(name: String, start: Date, seed: UInt64?) {
        self.name = name
        self.start = start
        self.seed = seed
    }
}

/// What the scenario menu needs from the app: the scenarios and opening them.
public struct ScenarioMenuActions {
    /// The Scenarios folder. The menu lists it, and new scenarios go there.
    public var folder: URL
    /// The scenario that's open.
    public var current: () -> ScenarioPackage?
    /// Saves the open scenario now, so a copy of it is up to date.
    public var save: () -> Void
    /// Opens a scenario in the panel, in place of the one open now.
    public var open: (ScenarioPackage) -> Void
    public var showInFinder: () -> Void
    /// Picks a scenario from anywhere to open, as Open Scenario… in the menu bar item does.
    public var openOther: () -> Void

    public init(folder: URL, current: @escaping () -> ScenarioPackage?, save: @escaping () -> Void,
                open: @escaping (ScenarioPackage) -> Void, showInFinder: @escaping () -> Void,
                openOther: @escaping () -> Void) {
        self.folder = folder
        self.current = current
        self.save = save
        self.open = open
        self.showInFinder = showInFinder
        self.openOther = openOther
    }

    /// The scenarios the menu lists, in Finder's order, with the open one among them.
    public func scenarios() -> [ScenarioPackage] {
        ScenarioLibrary.menuEntries(current: current(), in: folder)
    }

    /// The folder a scenario made in `mode` goes in, and the names already used there.
    func taken(for mode: ScenarioForm.Mode) -> Set<String> {
        guard mode == .edit, let current = current() else { return ScenarioLibrary.takenNames(in: folder) }
        // A renamed scenario's folder follows its name, so the names beside it are taken.
        return ScenarioLibrary.takenNames(in: current.url.deletingLastPathComponent(), except: current)
    }
}

/// The scenario menu's form: the open scenario's settings, or a new scenario's.
public struct ScenarioForm: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// The open scenario's name, start and seed.
        case edit
        /// A new scenario, with one blank formula.
        case new
        /// A copy of the open scenario, readings included.
        case duplicate
    }

    public var mode: Mode
    public var name: String
    public var start: Date
    /// The seed as typed: `0x5EEDF07E` or a whole number. Empty for the engine's own.
    public var seedText: String
    /// Folder names other scenarios use there, lowercased, since the Mac's disks ignore case.
    var taken: Set<String>
    /// Why the last try to make the scenario failed.
    public var failure: String?

    /// The name without spaces around it.
    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What stops the form from being saved, if anything.
    public var problem: String? {
        let name = trimmedName
        if name.isEmpty { return "Give the scenario a name." }
        if name.contains("[") || name.contains("]") { return "A name can't have square brackets in it." }
        if taken.contains(ScenarioLibrary.folderName(for: name).lowercased()) {
            return "There's already a scenario called “\(name)”."
        }
        if mode == .edit, Self.seed(from: seedText) == nil { return "A seed is a whole number, like 0x5EEDF07E." }
        return nil
    }

    /// A seed as the file writes it: `0x5EEDF07E`, or empty for the engine's own.
    public static func text(seed: UInt64?) -> String {
        seed.map { "0x" + String($0, radix: 16, uppercase: true) } ?? ""
    }

    /// The seed typed, read as the file reads it. `.some(nil)` is the engine's own; nil means it
    /// can't be read.
    public static func seed(from text: String) -> UInt64?? {
        let text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        if text.isEmpty { return .some(nil) }
        let parsed = text.lowercased().hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
        return parsed.map { .some($0) }
    }

    /// A seed picked at random, for "New seed".
    public static func randomSeed() -> UInt64 {
        UInt64.random(in: 1...UInt64(UInt32.max))
    }
}

extension ScenarioStore {
    /// Opens the form for editing the scenario's settings, or for a new one or a copy. `taken`
    /// holds the folder names other scenarios use there.
    public func openScenarioForm(_ mode: ScenarioForm.Mode, taken: Set<String> = []) {
        let name: String
        switch mode {
        case .edit: name = self.name
        case .new: name = ScenarioLibrary.uniqueName("New scenario", taken: taken)
        case .duplicate: name = ScenarioLibrary.uniqueName(self.name + " copy", taken: taken)
        }
        let start = mode == .new ? DateText.startOfYear(DateText.year(now)) : self.start
        scenarioForm = ScenarioForm(mode: mode, name: name, start: start,
                                    seedText: mode == .edit ? ScenarioForm.text(seed: seed) : "", taken: taken)
    }

    /// Opens the form for the menu, with the names the app's folders already use.
    public func openScenarioForm(_ mode: ScenarioForm.Mode, actions: ScenarioMenuActions) {
        openScenarioForm(mode, taken: actions.taken(for: mode))
    }

    public func closeScenarioForm() {
        if scenarioForm != nil { scenarioForm = nil }
    }

    /// Saves the form. Editing changes the open scenario, as one change undo takes back. A new
    /// scenario or a copy is written to the Scenarios folder and opened in the panel. Returns
    /// false when the form can't be saved, or making the scenario failed.
    @discardableResult
    public func submitScenarioForm(_ actions: ScenarioMenuActions?) async -> Bool {
        guard let form = scenarioForm, form.problem == nil else { return false }
        let name = form.trimmedName, start = form.start
        switch form.mode {
        case .edit:
            guard let seed = ScenarioForm.seed(from: form.seedText) else { return false }
            let old = settings
            closeScenarioForm()
            applySettingsChange(ScenarioSettings(name: name, start: start, seed: seed))
            if old.start != start { say("\(name) now starts \(DateText.dayMonthYear(start)). ⌘Z undoes it.") }
            return true
        case .new, .duplicate:
            guard let actions else { return false }
            let folder = actions.folder
            let made: Result<ScenarioPackage, Error>
            if form.mode == .new {
                made = await Task.detached(priority: .userInitiated) {
                    Result { try ScenarioLibrary.createBlank(name: name, start: start, in: folder) }
                }.value
            } else {
                guard let source = actions.current() else { return false }
                actions.save()
                made = await Task.detached(priority: .userInitiated) {
                    Result { try ScenarioLibrary.duplicate(source, name: name, start: start, in: folder) }
                }.value
            }
            switch made {
            case .success(let package):
                closeScenarioForm()
                actions.open(package)
                return true
            case .failure(let error):
                scenarioForm?.failure = "Couldn't make “\(name)”: \(error.localizedDescription)"
                return false
            }
        }
    }
}

extension ScenarioLibrary {
    /// The folder name for a scenario called `name`: slashes and colons become dashes, and leading
    /// dots go, so the folder isn't hidden.
    public static func folderName(for name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while text.hasPrefix(".") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        // Room for ".etf" within the 255 bytes a file name can have.
        while text.utf8.count > 200 { text.removeLast() }
        return text.isEmpty ? "Untitled" : text
    }

    /// Where a scenario called `name` goes in a folder.
    public static func package(named name: String, in folder: URL) -> ScenarioPackage {
        ScenarioPackage(url: folder.appendingPathComponent(folderName(for: name), isDirectory: true)
            .appendingPathExtension(ScenarioPackage.fileExtension))
    }

    /// The names of the scenario folders in a folder, lowercased.
    public static func takenNames(in folder: URL, except: ScenarioPackage? = nil) -> Set<String> {
        Set(scenarios(in: folder).filter { $0 != except }.map { $0.name.lowercased() })
    }

    /// `base`, else `base 2`, `base 3`… whichever no scenario there uses.
    public static func uniqueName(_ base: String, taken: Set<String>) -> String {
        var name = base, number = 2
        while taken.contains(folderName(for: name).lowercased()) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    /// What the scenario menu lists: the scenarios in the folder, and the open one wherever it
    /// is, in Finder's order.
    public static func menuEntries(current: ScenarioPackage?, in folder: URL) -> [ScenarioPackage] {
        var list = scenarios(in: folder)
        if let current, !list.contains(current) { list.append(current) }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A new scenario: one blank formula, to start from.
    public static func blank(name: String, start: Date) -> ScenarioDefinition {
        let template = ModelLibrary.blankFormula
        var slot = SlotSpec(name: template.slotName, model: template.slotModelName, kind: template.kind,
                            formula: template.formula, variable: template.variable, format: template.format, position: 0)
        slot.showsInFile = false  // the model's own choice, so the heading stays plain
        return ScenarioDefinition(name: name, start: start, slots: [slot])
    }

    /// Writes a new scenario with one blank formula, and returns its folder.
    public static func createBlank(name: String, start: Date, in folder: URL) throws -> ScenarioPackage {
        let package = package(named: name, in: folder)
        guard !FileManager.default.fileExists(atPath: package.url.path) else { throw CocoaError(.fileWriteFileExists) }
        try ScenarioDocument.create(blank(name: name, start: start), at: package)
        return package
    }

    /// Copies a scenario's folder under a new name and start, with its readings but not its
    /// cache, and returns the copy.
    public static func duplicate(_ source: ScenarioPackage, name: String, start: Date, in folder: URL) throws -> ScenarioPackage {
        let manager = FileManager.default
        let package = package(named: name, in: folder)
        guard !manager.fileExists(atPath: package.url.path) else { throw CocoaError(.fileWriteFileExists) }
        let parsed = try ScenarioFormat.parse(try source.readText())
        var file = parsed.file
        file.name = name
        file.start = start
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
