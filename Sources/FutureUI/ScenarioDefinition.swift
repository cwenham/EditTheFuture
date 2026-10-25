import Foundation
import FutureEngine

/// One slot of a scenario as it's set up when the scenario loads: a model plus how to show it.
public struct SlotSpec: Sendable {
    public var name: String
    /// The model's name, as the library calls it, e.g. "Savings account".
    public var model: String
    public var formula: String
    /// The variable drawn on the graph.
    public var variable: String
    /// Hex color, e.g. "#5AA9FF". nil uses the slot palette's color for its position.
    public var color: String?
    public var format: ValueFormat
    /// 0-based position in the bank (slot 1 is 0). nil takes the first free position.
    public var position: Int?
    /// The slot's own parameter and starting values, by name, in place of the formula's defaults.
    public var values: [String: Double]

    public init(name: String, model: String = "Custom formula", formula: String, variable: String, color: String? = nil,
                format: ValueFormat, position: Int? = nil, values: [String: Double] = [:]) {
        self.name = name
        self.model = model
        self.formula = formula
        self.variable = variable
        self.color = color
        self.format = format
        self.position = position
        self.values = values
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
            ModelLibrary.savingsAccount.slot(),
            ModelLibrary.indexFund.slot(),
            ModelLibrary.loan.slot(),
            // The library's versions count warming and price rises from the scenario's start; these
            // count from 2022, as the mockups do.
            SlotSpec(name: "Climate", model: "Seasonal temperature", formula: """
                step 1 month
                param mean = 11 range -20..35 by 0.5 label "Yearly mean" as temperature
                param swing = 9 range 0..30 by 0.5 label "Seasonal swing" as temperature
                param warming = 0.03 range 0..0.2 by 0.005 label "Warming per year" as temperature
                param heatwave = 20.2 range 0..45 by 0.1 label "Heatwave above" as temperature
                temp[t] = mean - swing * cos(2 * pi * (month - 1.5) / 12) + warming * (year - 2022) label "Temperature" as temperature
                when temp > heatwave emit Heatwave
                """, variable: "temp", format: .temperature),
            SlotSpec(name: "EnergyBill", model: "Energy bill", formula: """
                step 1 month
                param base = 70 range 0..500 by 5 label "Base cost per month" as currency
                param tariff = 1 range 0.5..3 by 0.01 label "Tariff"
                bill[t] = (base + 7.5 * max(0, 15 - Climate.temp) + 9 * max(0, Climate.temp - 22)) * tariff * 1.03 ^ (year - 2022) label "Monthly bill" as currency
                """, variable: "bill", format: .currency),
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

/// A slot name as people read it: "IndexFund" → "Index fund", "EnergyBill" → "Energy bill",
/// "USStocks" → "US stocks", "Savings2" → "Savings 2".
func displayName(_ slotName: String) -> String {
    let characters = Array(slotName)
    var words: [String] = []
    var current = ""
    for (index, character) in characters.enumerated() {
        if character == "_" || character == " " {
            if !current.isEmpty { words.append(current) }
            current = ""
            continue
        }
        if let previous = current.last {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let startsWord = (character.isUppercase && !previous.isUppercase)
                || (character.isUppercase && previous.isUppercase && next?.isLowercase == true)
                || (character.isNumber && !previous.isNumber)
                || (character.isLetter && previous.isNumber)
            if startsWord {
                words.append(current)
                current = ""
            }
        }
        current.append(character)
    }
    if !current.isEmpty { words.append(current) }
    guard let first = words.first else { return slotName }
    // Acronyms keep their capitals; other words after the first are lowercased.
    let rest = words.dropFirst().map { word in
        word.count > 1 && word.allSatisfy({ $0.isUppercase || $0.isNumber }) ? word : word.lowercased()
    }
    return ([first] + rest).joined(separator: " ")
}

/// The name formulas use for a slot people called `title`: "Rainy day fund" → "RainyDayFund".
/// Returns nil when nothing usable is left, or it wouldn't start with a letter.
func formulaName(fromTitle title: String) -> String? {
    let words = title.split { !($0.isLetter || $0.isNumber) }
    let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    guard let first = name.first, first.isLetter else { return nil }
    return name
}
