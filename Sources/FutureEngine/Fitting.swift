import Foundation

/// How far a reading was from what its step worked out before the reading replaced it
/// (docs/DESIGN.md, 8.4).
public struct Miss: Hashable, Sendable {
    /// The step's point.
    public var time: Date
    public var variable: String
    public var reading: Double
    /// What the step worked out before the reading replaced it.
    public var predicted: Double

    public init(time: Date, variable: String, reading: Double, predicted: Double) {
        self.time = time
        self.variable = variable
        self.reading = reading
        self.predicted = predicted
    }
}

/// What Refit may change, and which readings it compares.
public struct FitSettings: Sendable {
    /// The parameters and starting values to fit.
    public var values: [String]
    /// Only misses from this date on count. Earlier readings still correct the model.
    public var since: Date?
    /// The most rounds the solver takes from each starting point.
    public var maxRounds: Int

    public init(values: [String], since: Date? = nil, maxRounds: Int = 100) {
        self.values = values
        self.since = since
        self.maxRounds = maxRounds
    }
}

/// How far a slot's model misses the readings of one of its values.
public struct MissSummary: Hashable, Sendable {
    public var variable: String
    /// How many misses counted.
    public var count: Int
    /// The typical miss (the root mean square). When `isRatio`, a fraction of the reading: 0.018
    /// is 1.8%. Otherwise in the value's own units.
    public var typical: Double
    /// Misses are ratios when every reading of the value is above zero.
    public var isRatio: Bool

    public init(variable: String, count: Int, typical: Double, isRatio: Bool) {
        self.variable = variable
        self.count = count
        self.typical = typical
        self.isRatio = isRatio
    }
}

/// What Refit found.
public struct FitOutcome: Sendable {
    /// The fitted values, by name: the ones asked for. When the fit couldn't do better than the
    /// slot's own values, those.
    public var values: [String: Double]
    /// The misses with the slot's own values, or nil when what they work out can't be compared
    /// with the readings.
    public var before: [MissSummary]?
    /// The misses with `values`.
    public var after: [MissSummary]
    /// Whether `values` miss the readings by less than the slot's own values do.
    public var improved: Bool
    /// How many times the slot ran.
    public var runs: Int
}

public enum FitError: Error, Equatable, CustomStringConvertible {
    case notAuthored(slot: String)
    case noReadings(slot: String)
    case nothingToFit
    case unknownValue(slot: String, name: String)
    case setByReadings(name: String)
    case tooFewReadings(slot: String, have: Int, need: Int)
    case cantCompare(slot: String)

    public var description: String {
        switch self {
        case .notAuthored(let slot):
            return "\(slot)'s model can't be refitted. For now only formulas and scripts can."
        case .noReadings(let slot):
            return "\(slot) has no readings of its values to fit to."
        case .nothingToFit:
            return "Choose at least one value to fit."
        case .unknownValue(let slot, let name):
            return "\(slot) has no parameter or starting value called \(name)."
        case .setByReadings(let name):
            return "\(name) is set by its readings, so it can't be fitted."
        case .tooFewReadings(let slot, let have, let need):
            return "Fitting needs at least \(need) readings that follow an earlier one. \(slot) has \(have)."
        case .cantCompare(let slot):
            return "\(slot) works out values that can't be compared with its readings: infinite, not a number, "
                + "or zero or less where the readings are all above zero."
        }
    }
}

/// Everything fitting a slot needs, copied out of its scenario, so a fit can run on any thread
/// without holding up the scenario (docs/DESIGN.md, 8.4). The slots it reads come along as
/// recordings of what they computed, so each try runs this slot alone.
public struct SlotCopy: Sendable {
    /// A connection into the slot, with the other slot named.
    struct Link: Sendable {
        var from: String
        var variable: String
        var input: String
        var resampling: Resampling
        var timing: Timing
    }

    /// An event route into the slot, with the other slot named.
    struct RouteLink: Sendable {
        var from: String
        var kind: String
        var timing: Timing
    }

    public let name: String
    let model: any AuthoredModel
    let start: Date
    let calendar: Calendar
    let seed: UInt64
    let authored: [Event]
    let recurring: [RecurringEvent]
    let readings: [Reading]
    let links: [Link]
    let routes: [RouteLink]
    let upstream: [Recording]
    /// The slot's point at or after its last reading of a value. Each try runs this far.
    let end: Date

    /// The values the model marks with `fit`, leaving out any that have readings of their own.
    public let markedValues: [String]
    /// Every parameter and starting value without readings of its own: what Refit can offer.
    public let fittableValues: [String]

    /// Fits `settings.values` to the slot's readings. Runs on the calling thread; `isCancelled`
    /// is checked before each run of the slot.
    public func fit(_ settings: FitSettings, isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> FitOutcome {
        try Self.fit(model, copy: self, settings: settings, isCancelled: isCancelled)
    }
}

extension Scenario {
    /// Copies what fitting the slot needs (docs/DESIGN.md, 8.4). The slots it reads are computed
    /// as far as its last reading first.
    public func copyForFitting(_ slot: SlotID) throws -> SlotCopy {
        try validate()
        let slotName = name(of: slot)
        guard let model = model(of: slot) as? any AuthoredModel else { throw FitError.notAuthored(slot: slotName) }
        let descriptor = model.descriptor
        let valueNames = Set(descriptor.variables.filter { $0.causality == .output }.map(\.name))
        let readings = readings(in: slot)
        guard let last = readings.last(where: { valueNames.contains($0.variable) }) else {
            throw FitError.noReadings(slot: slotName)
        }
        let grid = TimeGrid(start: start, rate: descriptor.stepRate, calendar: calendar)
        let end = grid.point(grid.firstIndex(atOrAfter: last.time))

        var links: [SlotCopy.Link] = []
        var routes: [SlotCopy.RouteLink] = []
        var needed: [SlotID: [String]] = [:]
        for connection in connections where connection.to == slot {
            links.append(SlotCopy.Link(from: name(of: connection.from), variable: connection.variable,
                                       input: connection.input, resampling: connection.resampling,
                                       timing: connection.timing))
            if !(needed[connection.from] ?? []).contains(connection.variable) {
                needed[connection.from, default: []].append(connection.variable)
            }
        }
        for route in eventRoutes where route.to == slot {
            routes.append(SlotCopy.RouteLink(from: name(of: route.from), kind: route.kind, timing: route.timing))
            if needed[route.from] == nil { needed[route.from] = [] }
        }
        var upstream: [Recording] = []
        for from in needed.keys.sorted() {
            upstream.append(try recording(of: from, variables: needed[from]!, through: end))
        }

        let withReadings = Set(readings.map(\.variable))
        let fittable = (model.parameterNames + model.startingValueNames).filter { !withReadings.contains($0) }
        let marked = fittable.filter { descriptor.variable(named: $0)?.fittable == true }
        return SlotCopy(name: slotName, model: model, start: start, calendar: calendar, seed: seed,
                        authored: events(in: slot), recurring: recurringEvents(in: slot), readings: readings,
                        links: links, routes: routes, upstream: upstream, end: end,
                        markedValues: marked, fittableValues: fittable)
    }

    /// Fits the slot's values to its readings, without changing the scenario. The outcome's values
    /// become the slot's own values when the user applies them.
    public func refit(_ slot: SlotID, _ settings: FitSettings) throws -> FitOutcome {
        try copyForFitting(slot).fit(settings)
    }

    /// What another slot computed through `date`: the values a slot reads from it, and its events.
    private func recording(of slot: SlotID, variables: [String], through date: Date) throws -> Recording {
        try ensure(slot, through: date)
        let descriptor = descriptor(of: slot)
        let grid = TimeGrid(start: start, rate: descriptor.stepRate, calendar: calendar)
        let count = (grid.lastIndex(atOrBefore: date) ?? 0) + 1
        let columns = try variables.map { try series($0, of: slot, from: start, through: date).map(\.value) }
        let rows = (0..<count).map { index in columns.map { index < $0.count ? $0[index] : .nan } }
        var events: [Int: [GeneratedEvent]] = [:]
        for event in try generatedEvents(in: slot, through: date) {
            guard let index = grid.lastIndex(atOrBefore: event.time) else { continue }
            events[index, default: []].append(GeneratedEvent(kind: event.kind, values: event.values))
        }
        let recorded = ModelDescriptor(name: name(of: slot), stepRate: descriptor.stepRate,
                                       variables: variables.map { Variable(name: $0, causality: .output) },
                                       emits: descriptor.emits)
        return Recording(name: name(of: slot), descriptor: recorded, rows: rows, events: events)
    }
}

/// What a slot computed, played back in a slot copy.
struct Recording: Sendable {
    var name: String
    var descriptor: ModelDescriptor
    /// One row per point, in `descriptor.readable` order.
    var rows: [[Double]]
    /// The events it generated, by point.
    var events: [Int: [GeneratedEvent]]
}

/// Plays a recording back: the same values and events at the same points. Past its end it holds
/// the last values.
struct RecordedModel: TimelineModel {
    let recording: Recording

    var descriptor: ModelDescriptor { recording.descriptor }

    func start(_ context: StepContext) throws -> Int { 0 }

    func doStep(_ state: inout Int, _ context: StepContext) throws -> [GeneratedEvent] {
        state = context.index
        return recording.events[context.index] ?? []
    }

    func values(of state: Int) -> [String: Double] {
        Dictionary(zip(recording.descriptor.readable.map(\.name), readableValues(of: state))) { first, _ in first }
    }

    func readableValues(of state: Int) -> [Double] {
        guard let last = recording.rows.indices.last else { return [] }
        return recording.rows[min(state, last)]
    }
}

// MARK: Fitting

extension SlotCopy {
    fileprivate static func fit<Model: AuthoredModel>(_ model: Model, copy: SlotCopy, settings: FitSettings,
                                                      isCancelled: @escaping () -> Bool) throws -> FitOutcome {
        let names = settings.values
        guard !names.isEmpty else { throw FitError.nothingToFit }
        let settable = Set(model.parameterNames + model.startingValueNames)
        let withReadings = Set(copy.readings.map(\.variable))
        for name in names {
            guard settable.contains(name) else { throw FitError.unknownValue(slot: copy.name, name: name) }
            guard !withReadings.contains(name) else { throw FitError.setByReadings(name: name) }
        }

        // The slot on its own, reading recordings of the slots it reads.
        let scenario = Scenario(start: copy.start, calendar: copy.calendar, seed: copy.seed)
        scenario.recordsMisses = true
        for recording in copy.upstream {
            try scenario.addSlot(recording.name, model: RecordedModel(recording: recording))
        }
        let id = try scenario.addSlot(copy.name, model: model)
        for event in copy.authored { scenario.add(event, to: id) }
        for rule in copy.recurring { scenario.add(rule, to: id) }
        scenario.setReadings(copy.readings, for: id)
        for link in copy.links {
            guard let from = scenario.slotID(named: link.from) else { continue }
            scenario.connect(Connection(from: from, variable: link.variable, to: id, input: link.input,
                                        resampling: link.resampling, timing: link.timing))
        }
        for route in copy.routes {
            guard let from = scenario.slotID(named: route.from) else { continue }
            scenario.route(EventRoute(from: from, kind: route.kind, to: id, timing: route.timing))
        }
        try scenario.validate()

        let scoring = Scoring(readings: copy.readings, start: copy.start, since: settings.since)
        var runs = 0

        /// The slot's misses with these values of its own. A try whose model fails gives nil, as one
        /// whose values can't be compared does; with `strict`, the failure is thrown.
        func misses(with values: [String: Double], strict: Bool = false) throws -> [Miss]? {
            if isCancelled() { throw CancellationError() }
            runs += 1
            do {
                try scenario.replaceModel(of: id, with: try model.replacingValues(values))
                return try scenario.misses(in: id, through: copy.end)
            } catch let error as EngineError {
                if !strict, case .modelFailed = error { return nil }
                throw error
            } catch let error as ModelFailure {
                if strict { throw error }
                return nil
            }
        }

        // The slot as it is.
        guard let ownMisses = try misses(with: [:], strict: true) else { throw FitError.cantCompare(slot: copy.name) }
        let countable = scoring.countable(ownMisses)
        guard countable > names.count else {
            throw FitError.tooFewReadings(slot: copy.name, have: countable, need: names.count + 1)
        }
        var current: [Double] = []
        for name in names {
            current.append(try model.startingValues[name] ?? scenario.value(name, of: id, at: copy.start))
        }
        let before = scoring.residuals(ownMisses)

        // The solver, from the slot's own values and from the middle of each range.
        let variables = names.map { model.descriptor.variable(named: $0) }
        let lower = variables.map { $0?.minimum ?? -.infinity }
        let upper = variables.map { $0?.maximum ?? .infinity }
        let scales = names.indices.map { index -> Double in
            let width = upper[index] - lower[index]
            if width.isFinite, width > 0 { return width }
            return current[index].isFinite ? Swift.max(abs(current[index]), 1e-3) : 1
        }
        let solver = LeastSquares(lower: lower, upper: upper, scales: scales, maxRounds: settings.maxRounds) { values in
            guard let found = try misses(with: Dictionary(uniqueKeysWithValues: zip(names, values))) else { return nil }
            return scoring.residuals(found)?.map(\.value)
        }
        var starts = [current]
        let middles = names.indices.map { index -> Double in
            lower[index].isFinite && upper[index].isFinite ? (lower[index] + upper[index]) / 2 : current[index]
        }
        if middles != solver.clamp(current) { starts.append(middles) }
        var best: LeastSquares.Result?
        for start in starts {
            guard let result = try solver.minimize(from: start) else { continue }
            if best == nil || result.cost < best!.cost { best = result }
        }

        let ownCost = before.map { LeastSquares.sumOfSquares($0.map(\.value)) }
        guard let best, ownCost == nil || best.cost < ownCost! else {
            guard let before else { throw FitError.cantCompare(slot: copy.name) }
            let summary = scoring.summaries(before)
            return FitOutcome(values: Dictionary(uniqueKeysWithValues: zip(names, current)), before: summary,
                              after: summary, improved: false, runs: runs)
        }
        let fitted = Dictionary(uniqueKeysWithValues: zip(names, best.values))
        guard let fittedMisses = try misses(with: fitted), let after = scoring.residuals(fittedMisses) else {
            throw FitError.cantCompare(slot: copy.name)
        }
        return FitOutcome(values: fitted, before: before.map(scoring.summaries), after: scoring.summaries(after),
                          improved: true, runs: runs)
    }
}

/// Which misses count, and how each is measured (docs/DESIGN.md, 8.4).
private struct Scoring {
    /// Values whose readings are all above zero, so their misses are ratios.
    let ratios: Set<String>
    /// Values with a reading at or before the start, which the start takes. Without one, a value's
    /// first miss is left out: its step had nothing observed to start from.
    let anchored: Set<String>
    let since: Date?

    init(readings: [Reading], start: Date, since: Date?) {
        var positive: [String: Bool] = [:]
        var anchored = Set<String>()
        for reading in readings {
            positive[reading.variable] = (positive[reading.variable] ?? true) && reading.value > 0 && reading.value.isFinite
            if reading.time <= start { anchored.insert(reading.variable) }
        }
        ratios = Set(positive.filter(\.value).keys)
        self.anchored = anchored
        self.since = since
    }

    /// The misses that count, in order.
    private func counted(_ misses: [Miss]) -> [Miss] {
        var seen = Set<String>()
        return misses.filter { miss in
            if !anchored.contains(miss.variable), seen.insert(miss.variable).inserted { return false }
            if let since, miss.time < since { return false }
            return true
        }
    }

    func countable(_ misses: [Miss]) -> Int { counted(misses).count }

    /// Each counted miss as a ratio's log or a difference, or nil when one can't be measured.
    func residuals(_ misses: [Miss]) -> [(variable: String, value: Double)]? {
        var result: [(variable: String, value: Double)] = []
        for miss in counted(misses) {
            let value: Double
            if ratios.contains(miss.variable) {
                guard miss.predicted > 0 else { return nil }
                value = Foundation.log(miss.reading / miss.predicted)
            } else {
                value = miss.reading - miss.predicted
            }
            guard value.isFinite else { return nil }
            result.append((miss.variable, value))
        }
        return result
    }

    func summaries(_ residuals: [(variable: String, value: Double)]) -> [MissSummary] {
        var order: [String] = []
        var sums: [String: (count: Int, squares: Double)] = [:]
        for (variable, value) in residuals {
            if sums[variable] == nil { order.append(variable) }
            sums[variable, default: (0, 0)].count += 1
            sums[variable, default: (0, 0)].squares += value * value
        }
        return order.map { variable in
            let (count, squares) = sums[variable]!
            let rms = (squares / Double(count)).squareRoot()
            let isRatio = ratios.contains(variable)
            return MissSummary(variable: variable, count: count, typical: isRatio ? Foundation.exp(rms) - 1 : rms,
                               isRatio: isRatio)
        }
    }
}

/// Levenberg–Marquardt with bounds: the values that make the sum of squared residuals smallest.
/// Made for a few values and many residuals (docs/DESIGN.md, 8.4).
struct LeastSquares {
    struct Result {
        var values: [Double]
        var cost: Double
    }

    var lower: [Double]
    var upper: [Double]
    /// A typical size for each value, for the nudges that find slopes.
    var scales: [Double]
    var maxRounds: Int
    /// The residuals at some values, or nil when they can't be worked out, which counts as worse
    /// than any result.
    var residuals: ([Double]) throws -> [Double]?

    func clamp(_ values: [Double]) -> [Double] {
        values.indices.map { Swift.min(Swift.max(values[$0], lower[$0]), upper[$0]) }
    }

    static func sumOfSquares(_ values: [Double]) -> Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    /// The best values found from `start`, or nil when nothing can be worked out there.
    func minimize(from start: [Double]) throws -> Result? {
        let n = start.count
        var x = clamp(start)
        guard let first = try residuals(x), !first.isEmpty else { return nil }
        var r = first
        var cost = Self.sumOfSquares(r)
        guard cost.isFinite else { return nil }
        let m = r.count
        var lambda = 1e-3

        for _ in 0..<maxRounds where cost > 0 {
            // Slopes, by nudging each value, backwards when forwards would leave its range.
            var columns = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
            for j in 0..<n {
                let size = 1e-6 * Swift.max(abs(x[j]), scales[j])
                for nudge in [size, -size] {
                    var moved = x
                    moved[j] = x[j] + nudge
                    guard moved[j] >= lower[j], moved[j] <= upper[j], moved[j] != x[j],
                          let found = try residuals(moved), found.count == m else { continue }
                    let step = moved[j] - x[j]
                    let column = (0..<m).map { (found[$0] - r[$0]) / step }
                    if column.allSatisfy(\.isFinite) {
                        columns[j] = column
                        break
                    }
                }
            }

            // The normal equations: JᵀJ and Jᵀr.
            var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var g = [Double](repeating: 0, count: n)
            for j in 0..<n {
                for i in 0..<m { g[j] += columns[j][i] * r[i] }
                for k in 0...j {
                    var sum = 0.0
                    for i in 0..<m { sum += columns[j][i] * columns[k][i] }
                    a[j][k] = sum
                    a[k][j] = sum
                }
            }
            // A value at a bound, whose slope pushes it past the bound, stays put this round, and so
            // does one that changes nothing.
            let free = (0..<n).filter { j in
                a[j][j] > 0 && !(x[j] <= lower[j] && g[j] > 0) && !(x[j] >= upper[j] && g[j] < 0)
            }
            guard !free.isEmpty else { break }
            let largest = free.map { a[$0][$0] }.max()!

            var accepted = false, converged = false
            while lambda < 1e12 {
                var matrix = [[Double]](repeating: [Double](repeating: 0, count: free.count), count: free.count)
                var right = [Double](repeating: 0, count: free.count)
                for (p, j) in free.enumerated() {
                    right[p] = -g[j]
                    for (q, k) in free.enumerated() { matrix[p][q] = a[j][k] }
                    matrix[p][p] += lambda * Swift.max(a[j][j], 1e-12 * largest)
                }
                guard let step = Self.solve(matrix, right) else {
                    lambda *= 10
                    continue
                }
                var trial = x
                for (p, j) in free.enumerated() { trial[j] = x[j] + step[p] }
                trial = clamp(trial)
                if trial == x {
                    converged = true
                    break
                }
                if let found = try residuals(trial), found.count == m {
                    let trialCost = Self.sumOfSquares(found)
                    if trialCost.isFinite, trialCost < cost {
                        let decrease = (cost - trialCost) / cost
                        x = trial
                        r = found
                        cost = trialCost
                        lambda = Swift.max(lambda / 10, 1e-12)
                        accepted = true
                        converged = decrease < 1e-12
                        break
                    }
                }
                lambda *= 10
            }
            if !accepted || converged { break }
        }
        return Result(values: x, cost: cost)
    }

    /// Solves a small linear system by Gaussian elimination with partial pivoting, or nil when it
    /// has no single answer.
    static func solve(_ matrix: [[Double]], _ right: [Double]) -> [Double]? {
        var a = matrix, b = right
        let n = b.count
        for column in 0..<n {
            let pivot = (column..<n).max { abs(a[$0][column]) < abs(a[$1][column]) }!
            guard a[pivot][column] != 0, a[pivot][column].isFinite else { return nil }
            a.swapAt(column, pivot)
            b.swapAt(column, pivot)
            for row in (column + 1)..<n {
                let factor = a[row][column] / a[column][column]
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }
}
