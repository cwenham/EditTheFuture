#if os(macOS)
import AppIntents
import CoreSpotlight
import FutureCommands
import FutureEngine
import FutureUI
import SwiftUI

// Shortcuts, Siri and Spotlight (DESIGN.md, 10.2). The intents run inside the app and wait for its
// scenario to open. Reading runs at once; anything that edits asks first (DESIGN.md, 13).
// scripts/build-app.sh extracts their metadata into the app's Metadata.appintents, as Xcode would.

/// A slot in the scenario that's open. It's known by its formula name, which the scenario file
/// keeps, so a shortcut finds it again after the app restarts.
struct SlotEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Slot")
    static let defaultQuery = SlotQuery()

    let id: String
    let title: String
    let model: String
    let scenario: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(model) · \(scenario)")
    }

    @MainActor
    init(_ slot: ScenarioStore.SlotInfo, in store: ScenarioStore) {
        id = slot.name
        title = slot.title
        model = slot.model
        scenario = store.name
    }
}

@available(macOS 15.0, *)
extension SlotEntity: IndexedEntity {}

struct SlotQuery: EntityStringQuery {
    func entities(for identifiers: [SlotEntity.ID]) async throws -> [SlotEntity] {
        let all = await SlotIntents.entities()
        return identifiers.compactMap { id in all.first { $0.id.lowercased() == id.lowercased() } }
    }

    func entities(matching string: String) async throws -> [SlotEntity] {
        let wanted = string.lowercased().replacingOccurrences(of: " ", with: "")
        return await SlotIntents.entities().filter {
            $0.title.lowercased().replacingOccurrences(of: " ", with: "").contains(wanted) || $0.id.lowercased().contains(wanted)
        }
    }

    func suggestedEntities() async throws -> [SlotEntity] {
        await SlotIntents.entities()
    }
}

/// What a failed intent says.
struct IntentProblem: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

extension AppIntent {
    /// Asks before changing the scenario (DESIGN.md, 13). Cancelling throws, so nothing changes.
    func confirm(_ question: String, action: ConfirmationActionName) async throws {
        let dialog = IntentDialog(stringLiteral: question)
        if #available(macOS 15.0, *) {
            try await requestConfirmation(actionName: action, dialog: dialog)
        } else {
            try await requestConfirmation(result: .result(dialog: dialog), confirmationActionName: action)
        }
    }
}

/// A date picked in Shortcuts, as the day it falls on here, in the engine's UTC calendar.
func scenarioDay(_ date: Date?) -> PartialDate? {
    date.flatMap { PartialDate(day: $0, in: .current) }
}

// MARK: Reading

struct GetValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Value"
    static let description = IntentDescription(
        "Gets a slot’s value from the scenario open in Edit The Future, now or at a date, with its graph.")

    @Parameter(title: "Slot", requestValueDialog: "Which slot?")
    var slot: SlotEntity

    @Parameter(title: "Date", description: "Leave it empty for now.")
    var date: Date?

    @Parameter(title: "Value", description: "One of the slot’s values, such as balance. Leave it empty for the one its graph shows.")
    var value: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$slot) on \(\.$date)") {
            \.$value
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog & ShowsSnippetView {
        let store = await Outside.shared.store()
        let when = scenarioDay(date)?.date ?? Date()
        switch await store.value(slot: slot.id, variable: value, at: when, points: 80) {
        case .failure(let problem):
            throw IntentProblem(problem.description)
        case .success(let answer):
            return .result(value: answer.reading.value, dialog: IntentDialog(stringLiteral: answer.sentence),
                           view: ValueSnippet(answer: answer))
        }
    }
}

// MARK: Moving the panel

/// Shows a slot's graph. Spotlight runs it when a slot is picked from its results.
struct ShowSlotIntent: OpenIntent {
    static let title: LocalizedStringResource = "Show Timeline"
    static let description = IntentDescription("Shows Edit The Future’s panel with a slot’s graph, at a date.")

    @Parameter(title: "Slot", requestValueDialog: "Which slot?")
    var target: SlotEntity

    @Parameter(title: "Date", description: "Leave it empty to keep the cursor where it is.")
    var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$target) at \(\.$date)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let reply = await Outside.shared.handle(.command(.show(timeline: target.id, at: scenarioDay(date))), from: .appIntent)
        guard reply.ok else { throw IntentProblem(reply.message) }
        return .result()
    }
}

// MARK: Editing (each asks first)

enum MoneyEventChoice: String, AppEnum {
    case deposit, withdraw

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Kind of event")
    static let caseDisplayRepresentations: [MoneyEventChoice: DisplayRepresentation] = [
        .deposit: "Deposit",
        .withdraw: "Withdrawal",
    ]
}

enum RepeatChoice: String, AppEnum {
    case once, daily, weekly, fortnightly, monthly, quarterly, yearly

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Repeats")
    static let caseDisplayRepresentations: [RepeatChoice: DisplayRepresentation] = [
        .once: "Once", .daily: "Daily", .weekly: "Weekly", .fortnightly: "Fortnightly", .monthly: "Monthly",
        .quarterly: "Quarterly", .yearly: "Yearly",
    ]

    var repetition: Repetition? { Repetition(rawValue: rawValue) }
}

struct AddEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Deposit or Withdrawal"
    static let description = IntentDescription(
        "Adds a deposit or a withdrawal to a slot in Edit The Future, once or repeating. Asks before adding it.")

    @Parameter(title: "Slot", requestValueDialog: "Which slot?")
    var slot: SlotEntity

    @Parameter(title: "Kind", default: .deposit)
    var kind: MoneyEventChoice

    @Parameter(title: "Amount", description: "In the slot’s currency.", requestValueDialog: "How much?")
    var amount: Double

    @Parameter(title: "Date", description: "Leave it empty for now.")
    var date: Date?

    @Parameter(title: "Repeats", default: .once)
    var repeats: RepeatChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Add a \(\.$kind) of \(\.$amount) to \(\.$slot)") {
            \.$date
            \.$repeats
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = EventRequest(slot: slot.id, kind: kind.rawValue, values: ["amount": Amount(amount)],
                                   at: scenarioDay(date), every: repeats.repetition)
        try await confirm("Add " + SlotIntents.check(request) + "?", action: .add)
        return .result(dialog: IntentDialog(stringLiteral: try await SlotIntents.add(request)))
    }
}

struct SetParameterIntent: AppIntent {
    static let title: LocalizedStringResource = "Change a Parameter"
    static let description = IntentDescription(
        "Changes one of a slot’s parameters in Edit The Future from a date on, such as an interest rate. Asks before changing it.")

    @Parameter(title: "Slot", requestValueDialog: "Which slot?")
    var slot: SlotEntity

    @Parameter(title: "Parameter", description: "Its name, such as rate.", requestValueDialog: "Which parameter?")
    var parameter: String

    @Parameter(title: "Value", description: "For a percent, 4.5 means 4.5%.", requestValueDialog: "To what?")
    var value: Double

    @Parameter(title: "From", description: "Leave it empty for now.")
    var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$parameter) of \(\.$slot) to \(\.$value)") {
            \.$date
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = parameter.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw IntentProblem("Which parameter? Give its name, such as rate.") }
        let request = EventRequest(slot: slot.id, kind: "set", values: [name: Amount(value)], at: scenarioDay(date))
        try await confirm(SlotIntents.check(request) + "?", action: .set)
        return .result(dialog: IntentDialog(stringLiteral: try await SlotIntents.add(request)))
    }
}

struct AddReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Reading"
    static let description = IntentDescription(
        "Adds a reading of a slot’s value in Edit The Future, such as a balance from a statement or a meter reading. Readings correct the model up to now. Asks before adding it.")

    @Parameter(title: "Slot", requestValueDialog: "Which slot?")
    var slot: SlotEntity

    @Parameter(title: "Reading", description: "In the slot’s currency or unit. For a percent, 4.5 means 4.5%.",
               requestValueDialog: "What does it read?")
    var value: Double

    @Parameter(title: "Of", description: "Which of its values, such as balance. Leave it empty for the one its graph shows.")
    var variable: String?

    @Parameter(title: "Date", description: "Leave it empty for today.")
    var date: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Add a reading of \(\.$value) to \(\.$slot)") {
            \.$variable
            \.$date
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = variable?.trimmingCharacters(in: .whitespaces)
        let request = ReadingRequest(slot: slot.id, variable: name?.isEmpty == false ? name : nil, value: Amount(value),
                                     at: scenarioDay(date))
        let store = await Outside.shared.store()
        switch store.describe(request) {
        case .failure(let problem): throw IntentProblem(problem.description)
        case .success(let summary): try await confirm(summary + "?", action: .add)
        }
        let reply = await Outside.shared.handle(.command(.addReading(request)), from: .appIntent, confirmed: true)
        guard reply.ok else { throw IntentProblem(reply.message) }
        return .result(dialog: IntentDialog(stringLiteral: reply.message))
    }
}

// MARK: Copying

enum SnapshotChoice: String, AppEnum {
    case all, png, pdf, tsv, data

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Snapshot")
    static let caseDisplayRepresentations: [SnapshotChoice: DisplayRepresentation] = [
        .all: "Everything", .png: "Picture (PNG)", .pdf: "PDF", .tsv: "Table (tab-separated)", .data: "Data only",
    ]
}

struct CopySnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Snapshot"
    static let description = IntentDescription("Copies a snapshot of Edit The Future’s graphs to the clipboard.")

    @Parameter(title: "What", default: .all)
    var format: SnapshotChoice

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command: Command = format == .data ? .copyData : .copySnapshot(SnapshotFormat(rawValue: format.rawValue) ?? .all)
        let reply = await Outside.shared.handle(.command(command), from: .appIntent)
        guard reply.ok else { throw IntentProblem(reply.message) }
        return .result(dialog: IntentDialog(stringLiteral: reply.message))
    }
}

// MARK: Siri and Spotlight

struct EditTheFutureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetValueIntent(),
                    phrases: ["What's \(\.$slot) in \(.applicationName)", "Get \(\.$slot) from \(.applicationName)",
                              "Ask \(.applicationName) about \(\.$slot)"],
                    shortTitle: "Get Value", systemImageName: "chart.line.uptrend.xyaxis")
        AppShortcut(intent: ShowSlotIntent(),
                    phrases: ["Show \(\.$target) in \(.applicationName)", "Open \(\.$target) in \(.applicationName)"],
                    shortTitle: "Show Timeline", systemImageName: "rectangle.and.text.magnifyingglass")
        AppShortcut(intent: AddEventIntent(),
                    phrases: ["Add a deposit in \(.applicationName)", "Add to \(\.$slot) in \(.applicationName)"],
                    shortTitle: "Add Deposit", systemImageName: "plus.circle")
        AppShortcut(intent: AddReadingIntent(),
                    phrases: ["Add a reading in \(.applicationName)", "Add a reading to \(\.$slot) in \(.applicationName)"],
                    shortTitle: "Add Reading", systemImageName: "gauge.with.needle")
        AppShortcut(intent: CopySnapshotIntent(),
                    phrases: ["Copy a snapshot from \(.applicationName)", "Copy \(.applicationName) snapshot"],
                    shortTitle: "Copy Snapshot", systemImageName: "doc.on.clipboard")
    }
}

@MainActor
enum SlotIntents {
    static func entities() async -> [SlotEntity] {
        let store = await Outside.shared.store()
        return store.slots.map { SlotEntity($0, in: store) }
    }

    /// What an event would add, or why it can't be added.
    static func check(_ request: EventRequest) async throws -> String {
        switch await Outside.shared.store().describe(request) {
        case .failure(let problem): throw IntentProblem(problem.description)
        case .success(let summary): return summary
        }
    }

    /// Adds an event once it's been confirmed, and says what was added.
    static func add(_ request: EventRequest) async throws -> String {
        let reply = await Outside.shared.handle(.command(.addEvent(request)), from: .appIntent, confirmed: true)
        guard reply.ok else { throw IntentProblem(reply.message) }
        return reply.message
    }

    /// The slots in Siri's phrases and Spotlight's results follow the open scenario's.
    private static var indexed: [String] = []

    static func slotsChanged(in store: ScenarioStore) {
        EditTheFutureShortcuts.updateAppShortcutParameters()
        guard #available(macOS 15.0, *) else { return }
        let entities = store.slots.map { SlotEntity($0, in: store) }
        let gone = indexed.filter { id in !entities.contains { $0.id == id } }
        indexed = entities.map(\.id)
        Task {
            let index = CSSearchableIndex.default()
            if !gone.isEmpty { try? await index.deleteAppEntities(identifiedBy: gone, ofType: SlotEntity.self) }
            try? await index.indexAppEntities(entities)
        }
    }
}

// MARK: The snippet

/// What Siri and Shortcuts show with a value: the slot, the value, and its line.
struct ValueSnippet: View {
    let answer: ScenarioStore.OutsideValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(answer.slotTitle).font(.headline)
            Text(answer.reading.text).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            SnippetLine(samples: answer.line, marker: answer.date, color: Color(hex: answer.colorHex))
                .frame(height: 96)
            Text(answer.sentence).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// A slot's line, scaled to fit, with a dot at the date asked about. Values that aren't finite
/// are left out, and the range is always a valid one (CLAUDE.md, extreme values).
struct SnippetLine: View {
    let samples: [Sample]
    let marker: Date
    let color: Color

    var body: some View {
        Canvas { context, size in
            let finite = samples.filter { $0.value.isFinite }
            guard let first = finite.first?.time, let last = finite.last?.time, last > first,
                  let low = finite.map(\.value).min(), let high = finite.map(\.value).max() else { return }
            let domain = ScenarioStore.laneDomain(low: low, high: high)
            let span = last.timeIntervalSince(first)
            func point(_ time: Date, _ value: Double) -> CGPoint {
                let x = time.timeIntervalSince(first) / span * size.width
                let fraction = (min(max(value, domain.lowerBound), domain.upperBound) - domain.lowerBound)
                    / (domain.upperBound - domain.lowerBound)
                return CGPoint(x: x, y: size.height * (1 - fraction))
            }
            var path = Path()
            for (index, sample) in finite.enumerated() {
                let p = point(sample.time, sample.value)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let at = finite.last(where: { $0.time <= marker }) ?? finite.first {
                let p = point(at.time, at.value)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
            }
        }
    }
}
#endif
