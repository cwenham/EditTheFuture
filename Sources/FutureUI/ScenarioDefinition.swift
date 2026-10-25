import Foundation
import FutureEngine

/// One slot of a scenario as the app sets it up: a formula plus how to show it.
public struct SlotSpec: Sendable {
    public var name: String
    public var formula: String
    /// The variable drawn on the graph.
    public var variable: String
    /// Hex color, e.g. "#5AA9FF". Defaults to the slot palette by position.
    public var color: String?
    public var format: ValueFormat
    /// Short description under the slot name, e.g. "Formula · monthly · 4.5% interest".
    public var summary: String

    public init(name: String, formula: String, variable: String, color: String? = nil, format: ValueFormat, summary: String) {
        self.name = name
        self.formula = formula
        self.variable = variable
        self.color = color
        self.format = format
        self.summary = summary
    }
}

/// An authored event to add when the scenario loads.
public struct InitialEvent: Sendable {
    public var slot: String
    public var event: Event

    public init(slot: String, event: Event) {
        self.slot = slot
        self.event = event
    }
}

public struct ScenarioDefinition: Sendable {
    public var name: String
    public var start: Date
    public var slots: [SlotSpec]
    public var events: [InitialEvent]

    public init(name: String, start: Date, slots: [SlotSpec], events: [InitialEvent] = []) {
        self.name = name
        self.start = start
        self.slots = slots
        self.events = events
    }
}

/// Default slot colors by position; they match the hardware LEDs (docs/UI.md, 2.2).
public enum SlotPalette {
    public static let colors = ["#5AA9FF", "#4FD1A5", "#FF9F43", "#FF7A93", "#C3A6FF", "#F2D45C", "#46C8E0", "#E8A0D0"]

    public static func color(forSlotAt index: Int) -> String {
        colors[index % colors.count]
    }
}

extension ScenarioDefinition {
    /// The "Home & money" scenario from the mockups.
    public static let homeAndMoney = ScenarioDefinition(
        name: "Home & money",
        start: DateText.startOfYear(2022),
        slots: [
            SlotSpec(name: "Savings", formula: """
                step 1 month
                param rate = 4.5%
                param monthly = 400
                init balance = 18000
                balance[t] = balance[t-1] * (1 + rate / 12) + monthly
                on deposit: balance += event.amount
                on withdraw: balance -= event.amount
                """, variable: "balance", format: .currency, summary: "Formula · monthly · deposits with interest"),
            SlotSpec(name: "IndexFund", formula: """
                step 1 month
                param growth = 6%
                param contribution = 500
                init value = 42000
                value[t] = value[t-1] * (1 + growth / 12) + contribution
                on deposit: value += event.amount
                on withdraw: value -= event.amount
                """, variable: "value", format: .currency, summary: "Formula · monthly · median growth (bands arrive with ensembles)"),
            SlotSpec(name: "Mortgage", formula: """
                step 1 month
                param rate = 3.1%
                param payment = 1324
                init owed = 310000
                owed[t] = max(0, owed[t-1] * (1 + rate / 12) - payment)
                on overpay: owed = max(0, owed - event.amount)
                on deposit: owed = max(0, owed - event.amount)
                """, variable: "owed", format: .currency, summary: "Formula · monthly · balance owed"),
            SlotSpec(name: "Climate", formula: """
                step 1 month
                param warming = 0.03
                temp[t] = 11 - 9 * cos(2 * pi * (month - 1.5) / 12) + warming * (year - 2022)
                when temp > 20.2 emit Heatwave
                """, variable: "temp", format: .temperature, summary: "Seasonal model · monthly mean · emits Heatwave"),
            SlotSpec(name: "EnergyBill", formula: """
                step 1 month
                param tariff = 1
                bill[t] = (70 + 7.5 * max(0, 15 - Climate.temp) + 9 * max(0, Climate.temp - 22)) * tariff * 1.03 ^ (year - 2022)
                """, variable: "bill", format: .currency, summary: "Formula · monthly · reads Climate.temp"),
        ],
        events: [
            InitialEvent(slot: "Savings", event: Event(time: date(2028, 8, 1), kind: "withdraw", values: ["amount": 6000])),
            InitialEvent(slot: "IndexFund", event: Event(time: date(2031, 6, 1), kind: "withdraw", values: ["amount": 20000])),
            InitialEvent(slot: "Mortgage", event: Event(time: date(2029, 1, 1), kind: "overpay", values: ["amount": 10000])),
            InitialEvent(slot: "EnergyBill", event: Event.set(["tariff": 1.12], at: date(2027, 4, 1))),
        ]
    )

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DateText.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

/// A slot name as people read it: "IndexFund" → "Index fund", "EnergyBill" → "Energy bill".
func displayName(_ slotName: String) -> String {
    var words: [String] = []
    var current = ""
    for character in slotName {
        if character.isUppercase, !current.isEmpty {
            words.append(current)
            current = ""
        }
        current.append(character == "_" ? " " : character)
    }
    if !current.isEmpty { words.append(current) }
    guard let first = words.first else { return slotName }
    return ([first] + words.dropFirst().map { $0.lowercased() }).joined(separator: " ")
}
