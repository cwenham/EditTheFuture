import Foundation
import FutureDocument
import FutureEngine
import FutureScript

// The store's scenario as `scenario.md` says it, and back (docs/DESIGN.md, 15.2).

extension ScenarioDefinition {
    /// The scenario a file describes, with the readings found for its slots, by slot name.
    public init(file: ScenarioFile, readings: [String: ReadingSet] = [:], exchangeRates: ExchangeRates = .none) {
        self.init(name: file.name, start: file.start, seed: file.seed, currency: file.currency, rates: file.rates,
                  numbers: file.numbers, exchangeRates: exchangeRates, slots: file.slots.map { SlotSpec(file: $0, readings: SlotReadings(sources: $0.readings, set: readings[$0.name] ?? .empty)) })
    }

    /// The same, with each source's readings apart, as `ReadingLoader` loads them.
    public init(file: ScenarioFile, loaded: [String: LoadedReadings], exchangeRates: ExchangeRates = .none) {
        self.init(name: file.name, start: file.start, seed: file.seed, currency: file.currency, rates: file.rates,
                  numbers: file.numbers, exchangeRates: exchangeRates, slots: file.slots.map {
            SlotSpec(file: $0, readings: SlotReadings(sources: $0.readings, parts: loaded[$0.name]?.parts ?? []))
        })
    }
}

extension SlotSpec {
    init(file slot: SlotFile, readings: SlotReadings) {
        let kind = ModelKind(slot.language)
        // What the graph shows, and how: as the file says, else from the model.
        var variable = slot.shows ?? ""
        var format = slot.format.flatMap(ValueFormat.init(rawValue:))
        if slot.problem == nil, variable.isEmpty || format == nil,
           let model = try? SlotConfig.model(kind: kind, source: slot.source, name: slot.name, values: slot.values) {
            let descriptor = model.descriptor
            if variable.isEmpty {
                variable = descriptor.variables.first { $0.causality == .output }?.name ?? descriptor.readable.first?.name ?? ""
            }
            if format == nil { format = ValueFormat(descriptor.variable(named: variable)?.quantity) }
        }
        self.init(name: slot.name, model: slot.model.isEmpty ? kind.customModelName : slot.model, kind: kind,
                  formula: slot.source, variable: variable, color: slot.color.map { "#" + $0 }, format: format ?? .number,
                  currency: slot.currency, position: slot.position, values: slot.values, events: slot.events, rules: slot.rules,
                  readings: readings, problem: slot.problem)
        showsInFile = slot.shows != nil
        formatInFile = slot.format != nil
    }
}

extension ModelKind {
    init(_ language: ModelLanguage) {
        switch language {
        case .formula: self = .formula
        case .lua: self = .script(.lua)
        case .python: self = .script(.python)
        }
    }

    var language: ModelLanguage {
        switch self {
        case .script(.lua): return .lua
        case .script(.python): return .python
        default: return .formula
        }
    }

    /// What a slot's model is called when it isn't from the library. The file leaves it out.
    var customModelName: String {
        switch self {
        case .script(let language): return "Custom \(language.title) script"
        default: return "Custom formula"
        }
    }
}

extension ValueFormat {
    /// How a value of this quantity is written.
    init(_ quantity: Quantity?) {
        switch quantity {
        case .percent: self = .percent
        case .currency: self = .currency
        case .temperature: self = .temperature
        case .number, nil: self = .number
        }
    }
}

extension ScenarioStore {
    /// The scenario as its file says it.
    public func scenarioFile() -> ScenarioFile {
        Self.file(settings, configs: configs, descriptors: descriptors)
    }

    nonisolated static func file(_ settings: ScenarioSettings, configs: [SlotConfig], descriptors: [ModelDescriptor?]) -> ScenarioFile {
        let slots = configs.enumerated().map { index, config -> SlotFile in
            let descriptor = descriptors.indices.contains(index) ? descriptors[index] : nil
            let percents = Set((descriptor?.variables ?? []).filter { $0.quantity == .percent }.map(\.name))
            // The model's own choices are left out unless the file wrote them.
            let usualVariable = descriptor.map {
                $0.variables.first { $0.causality == .output }?.name ?? $0.readable.first?.name ?? ""
            }
            let usualFormat = ValueFormat(descriptor?.variable(named: config.variable)?.quantity)
            let writeShows = !config.variable.isEmpty && (config.showsInFile || config.variable != usualVariable)
            let writeFormat = config.formatInFile || (descriptor != nil && config.format != usualFormat)
            let color = config.color.map { ($0.hasPrefix("#") ? String($0.dropFirst()) : $0).uppercased() }
            return SlotFile(position: config.position, name: config.name,
                            model: config.model == config.kind.customModelName ? "" : config.model,
                            language: config.kind.language, source: config.formula,
                            shows: writeShows ? config.variable : nil,
                            format: writeFormat ? config.format.rawValue : nil, currency: config.currency, color: color,
                            values: config.values, percentNames: percents, events: config.events, rules: config.rules,
                            readings: config.readings.sources, problem: config.problem)
        }
        return ScenarioFile(name: settings.name, start: settings.start, seed: settings.seed, currency: settings.currency,
                            rates: settings.rates, numbers: settings.numbers, slots: slots)
    }

    /// A definition as its file would say it, for writing a new scenario.
    nonisolated static func file(for definition: ScenarioDefinition) -> ScenarioFile {
        let configs = Self.configs(from: definition)
        return file(ScenarioSettings(name: definition.name, start: definition.start, seed: definition.seed,
                                     currency: definition.currency, rates: definition.rates, numbers: definition.numbers),
                    configs: configs,
                    descriptors: assemble(configs).descriptors)
    }

    /// Brings the scenario in line with its file after another app changed it (docs/DESIGN.md,
    /// 15.1). Slots keep their identity by name, then by position, and unchanged events keep their
    /// ids, so only what changed is computed again. It's one change, which undo takes back; a new
    /// start or seed builds everything again and starts undo afresh.
    public func reload(from definition: ScenarioDefinition) {
        var incoming = Self.configs(from: definition)
        let incomingNames = Set(incoming.map(\.name))
        var used = Set<UUID>()
        for index in incoming.indices {
            let name = incoming[index].name, position = incoming[index].position
            guard let old = configs.first(where: { !used.contains($0.id) && $0.name == name })
                    ?? configs.first(where: { !used.contains($0.id) && $0.position == position && !incomingNames.contains($0.name) })
            else { continue }
            used.insert(old.id)
            incoming[index].id = old.id
            var unused = old.events
            for event in incoming[index].events.indices {
                let new = incoming[index].events[event]
                if let found = unused.firstIndex(where: { $0.time == new.time && $0.kind == new.kind && $0.values == new.values }) {
                    incoming[index].events[event].id = unused.remove(at: found).id
                }
            }
            var unusedRules = old.rules
            for rule in incoming[index].rules.indices {
                var new = incoming[index].rules[rule]
                if let found = unusedRules.firstIndex(where: { new.id = $0.id; return $0 == new }) {
                    incoming[index].rules[rule].id = unusedRules.remove(at: found).id
                }
            }
        }
        let focus = slots.indices.contains(focusedIndex) ? focused.id : nil
        if definition.start != start || definition.seed != seed {
            replaceScenario(ScenarioSettings(name: definition.name, start: definition.start, seed: definition.seed,
                                             currency: definition.currency, rates: definition.rates, numbers: definition.numbers),
                            configs: incoming, focus: focus)
            return
        }
        if name != definition.name { name = definition.name }
        // A new currency is written into the slots as they're built again, so it goes first.
        setMoneySettings(currency: definition.currency, rates: definition.rates, numbers: definition.numbers)
        applySlotChange(incoming, focus: focus)
    }

    /// Each slot's fingerprint as the store has it now (docs/DESIGN.md, 15.5).
    func fingerprints(libraries: [ScriptLanguage: String]) -> [String?] {
        Self.fingerprints(configs, descriptors: descriptors, start: start, seed: seed, libraries: libraries,
                          conversions: slots.map(\.conversions), rates: exchangeRates)
    }

    /// What made each slot's results (docs/DESIGN.md, 15.5): a hash of its model and values, its
    /// events and readings, the scenario's start and seed, the engine's version, the script
    /// libraries, and the same for every slot it reads or listens to, however far upstream. nil for
    /// paused slots.
    /// A slot that converts money counts its currencies and their rates too (docs/DESIGN.md, 5.11).
    nonisolated static func fingerprints(_ configs: [SlotConfig], descriptors: [ModelDescriptor?], start: Date, seed: UInt64?,
                                         libraries: [ScriptLanguage: String], conversions: [[SlotConversion]] = [],
                                         rates: ExchangeRates = .none) -> [String?] {
        var rateDigests: [Currency: String] = [:]
        func digest(_ currency: Currency) -> String {
            if let known = rateDigests[currency] { return known }
            var hash = Fingerprint()
            if let series = rates.series[currency] {
                for (time, rate) in zip(series.times, series.perDollar) {
                    hash.add(time.timeIntervalSinceReferenceDate)
                    hash.add(rate)
                }
            }
            let text = hash.finish()
            rateDigests[currency] = text
            return text
        }
        let index = Dictionary(configs.enumerated().map { ($0.element.name, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let own = configs.enumerated().map { offset, config -> String? in
            guard offset < descriptors.count, descriptors[offset] != nil, config.problem == nil else { return nil }
            var hash = Fingerprint()
            hash.add("Edit The Future slot")
            hash.add(SlotCache.formatVersion)
            hash.add(Scenario.engineVersion)
            hash.add(start.timeIntervalSinceReferenceDate)
            hash.add(seed ?? Scenario.defaultSeed)
            hash.add(config.name)
            hash.add(config.kind.language.rawValue)
            hash.add(config.formula)
            if case .script(let language) = config.kind { hash.add(libraries[language] ?? "") }
            for (name, value) in config.values.sorted(by: { $0.key < $1.key }) {
                hash.add(name)
                hash.add(value)
            }
            for event in config.events.sorted(by: { ($0.time, $0.kind, $0.id.uuidString) < ($1.time, $1.kind, $1.id.uuidString) }) {
                hash.add(event.id.uuidString)
                hash.add(EventIdentity.key(event))
            }
            for rule in config.rules.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                hash.add(rule.id.uuidString)
                hash.add(EventIdentity.key(rule))
            }
            hash.add(config.readings.set.digest)
            for conversion in conversions.indices.contains(offset) ? conversions[offset] : [] {
                hash.add("converts " + conversion.reading + " " + conversion.pair.description)
                hash.add(digest(conversion.pair.from))
                hash.add(digest(conversion.pair.to))
            }
            return hash.finish()
        }
        return configs.indices.map { start -> String? in
            guard own[start] != nil else { return nil }
            // Every slot this one depends on, at any distance (lagged loops included).
            var seen: Set<Int> = [start]
            var pending = [start]
            while let next = pending.popLast() {
                let descriptor = descriptors.indices.contains(next) ? descriptors[next] : nil
                let upstream = (descriptor?.inputs.compactMap { $0.source?.slot } ?? []) + (descriptor?.subscriptions.map(\.slot) ?? [])
                for name in upstream {
                    guard let found = index[name], seen.insert(found).inserted else { continue }
                    pending.append(found)
                }
            }
            var hash = Fingerprint()
            for slot in seen.sorted(by: { configs[$0].name < configs[$1].name }) {
                guard let part = own[slot] else { return nil }
                hash.add(part)
            }
            return hash.finish()
        }
    }
}

/// The script libraries' contents as a hash, so cached results of scripts that might import them
/// aren't used after a library changes (docs/DESIGN.md, 15.5).
enum ScriptLibraryDigest {
    static func compute() -> [ScriptLanguage: String] {
        var digests: [ScriptLanguage: String] = [:]
        for language in ScriptLanguage.allCases {
            let folder = ScriptPrograms.librariesFolder(for: language)
            var hash = Fingerprint()
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?
                .compactMap { $0 as? URL }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path < $1.path } ?? []
            for file in files {
                hash.add(String(file.path.dropFirst(folder.path.count)))
                hash.add((try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } ?? "")
            }
            digests[language] = hash.finish()
        }
        return digests
    }
}
