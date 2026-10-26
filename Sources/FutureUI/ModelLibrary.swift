import Foundation
import FutureEngine
import FutureScript

/// Where a model comes from (docs/DESIGN.md, 6.1). Formulas and scripts run so far.
public enum ModelKind: Hashable, Sendable {
    case formula
    /// A Lua or Python script (docs/DESIGN.md, 6.4).
    case script(ScriptLanguage)
    /// A WebAssembly or native plug-in. Planned.
    case plugin
    /// A model on a server or a paired device. Planned.
    case remote

    public var title: String {
        switch self {
        case .formula: return "Formula"
        case .script(let language): return language.title
        case .plugin: return "Plug-in"
        case .remote: return "Remote"
        }
    }
}

/// A model in the library: a starting point that's copied into a slot when it's added
/// (docs/UI.md, 5.7).
public struct ModelTemplate: Identifiable, Hashable, Sendable {
    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case money, growth, climate, health, physics, blank, plugins

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .money: return "Money"
            case .growth: return "Growth"
            case .climate: return "Climate"
            case .health: return "Health"
            case .physics: return "Physics"
            case .blank: return "Blank"
            case .plugins: return "Plug-ins"
            }
        }
    }

    public let id: String
    public let name: String
    public let category: Category
    public let kind: ModelKind
    /// One line for the picker, e.g. "Deposits with monthly interest".
    public let summary: String
    /// The name a slot gets when the model is added, e.g. "Savings". A number is added when it's taken.
    public let slotName: String
    public let formula: String
    /// The variable the graph shows.
    public let variable: String
    public let format: ValueFormat

    public init(id: String, name: String, category: Category, kind: ModelKind = .formula, summary: String,
                slotName: String, formula: String, variable: String, format: ValueFormat) {
        self.id = id
        self.name = name
        self.category = category
        self.kind = kind
        self.summary = summary
        self.slotName = slotName
        self.formula = formula
        self.variable = variable
        self.format = format
    }

    /// The template as a slot of a scenario definition.
    public func slot(named name: String? = nil, values: [String: Double] = [:], position: Int? = nil) -> SlotSpec {
        SlotSpec(name: name ?? slotName, model: self.name, kind: kind, formula: formula, variable: variable, format: format,
                 position: position, values: values)
    }

    /// What a slot's model is called when it starts from this template: blank ones are the slot's own.
    var slotModelName: String {
        guard category == .blank else { return name }
        switch kind {
        case .script(let language): return "Custom \(language.title) script"
        default: return "Custom formula"
        }
    }
}

/// The models that come with the app.
public enum ModelLibrary {
    public static let all: [ModelTemplate] = [
        savingsAccount, indexFund, loan, drawdown, prices,
        compoundGrowth, logisticGrowth, linearTrend,
        seasonalTemperature, energyBill,
        bodyWeight,
        radioactiveDecay, batteryCapacity,
        predatorPrey,
        blankFormula, blankLua,
    ] + (ScriptLanguage.python.isAvailable ? [marketSwings, blankPython] : [])

    public static func template(id: String) -> ModelTemplate? {
        all.first { $0.id == id }
    }

    /// Models whose name, summary or category contains every word of `query`.
    public static func search(_ query: String) -> [ModelTemplate] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return all }
        return all.filter { template in
            let text = [template.name, template.summary, template.category.title, template.kind.title].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// The model a command means: "savings account", "savings", "loan", "mortgage".
    public static func named(_ text: String) -> ModelTemplate? {
        let wanted = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let squashed = wanted.replacingOccurrences(of: " ", with: "")
        return all.first { $0.name.lowercased() == wanted || $0.slotName.lowercased() == squashed }
            ?? all.first { $0.name.lowercased().hasPrefix(wanted) }
            ?? search(wanted).first
    }

    // MARK: Money

    public static let savingsAccount = ModelTemplate(
        id: "savings-account", name: "Savings account", category: .money,
        summary: "Monthly deposits that earn interest", slotName: "Savings", formula: """
            step 1 month
            param rate = 4.5% range 0%..15% by 0.1% label "Interest rate"
            param monthly = 400 range 0..5000 by 50 label "Monthly deposit" as currency
            init balance = 18000 label "Balance" as currency
            balance[t] = balance[t-1] * (1 + rate / 12) + monthly
            on deposit: balance += event.amount
            on withdraw: balance -= event.amount
            """, variable: "balance", format: .currency)

    public static let indexFund = ModelTemplate(
        id: "index-fund", name: "Index fund", category: .money,
        summary: "Median market growth plus monthly contributions", slotName: "IndexFund", formula: """
            step 1 month
            param growth = 6% range -5%..15% by 0.1% label "Growth per year"
            param contribution = 500 range 0..5000 by 50 label "Monthly contribution" as currency
            init value = 42000 label "Value" as currency
            value[t] = value[t-1] * (1 + growth / 12) + contribution
            on deposit: value += event.amount
            on withdraw: value -= event.amount
            """, variable: "value", format: .currency)

    public static let loan = ModelTemplate(
        id: "loan", name: "Loan or mortgage", category: .money,
        summary: "What's owed, paid off monthly with interest", slotName: "Mortgage", formula: """
            step 1 month
            param rate = 3.1% range 0%..12% by 0.05% label "Interest rate"
            param payment = 1324 range 0..10000 by 10 label "Monthly payment" as currency
            init owed = 310000 label "Amount owed" as currency
            owed[t] = max(0, owed[t-1] * (1 + rate / 12) - payment)
            on overpay: owed = max(0, owed - event.amount)
            on deposit: owed = max(0, owed - event.amount)
            """, variable: "owed", format: .currency)

    public static let drawdown = ModelTemplate(
        id: "retirement-drawdown", name: "Retirement drawdown", category: .money,
        summary: "A pot that pays out monthly, rising with inflation", slotName: "Pension", formula: """
            step 1 month
            param growth = 4% range -5%..12% by 0.1% label "Growth per year"
            param withdrawal = 2500 range 0..20000 by 50 label "Monthly withdrawal" as currency
            param inflation = 2.5% range 0%..10% by 0.1% label "Inflation"
            init pot = 600000 label "Pot" as currency
            pot[t] = max(0, pot[t-1] * (1 + growth / 12) - withdrawal * (1 + inflation) ^ (days / 365.2425))
            on deposit: pot += event.amount
            on withdraw: pot = max(0, pot - event.amount)
            when pot <= 0 emit Depleted
            """, variable: "pot", format: .currency)

    public static let prices = ModelTemplate(
        id: "price-level", name: "Price level", category: .money,
        summary: "What $100 of shopping costs as prices rise", slotName: "Prices", formula: """
            step 1 month
            param inflation = 2.5% range -2%..15% by 0.1% label "Inflation per year"
            init price = 100 label "Price" as currency
            price[t] = price[t-1] * (1 + inflation) ^ (1 / 12)
            """, variable: "price", format: .currency)

    // MARK: Growth

    public static let compoundGrowth = ModelTemplate(
        id: "compound-growth", name: "Compound growth", category: .growth,
        summary: "Grows by the same percent every year", slotName: "Growth", formula: """
            step 1 year
            param growth = 3% range -20%..50% by 0.5% label "Growth per year"
            init amount = 1000 label "Amount"
            amount[t] = amount[t-1] * (1 + growth)
            """, variable: "amount", format: .number)

    public static let logisticGrowth = ModelTemplate(
        id: "logistic-growth", name: "Logistic growth", category: .growth,
        summary: "Grows fast, then levels off at a carrying capacity", slotName: "Population", formula: """
            step 1 month
            timeunit year
            param r = 0.5 range 0..3 by 0.05 label "Growth rate per year"
            param capacity = 10000 range 1..1000000 by 100 label "Carrying capacity"
            init population = 100 label "Population"
            dpopulation/dt = r * population * (1 - population / capacity)
            when population > 0.9 * capacity emit NearCapacity
            """, variable: "population", format: .number)

    public static let linearTrend = ModelTemplate(
        id: "linear-trend", name: "Linear trend", category: .growth,
        summary: "Changes by the same amount every year", slotName: "Trend", formula: """
            step 1 month
            param perYear = 120 range -10000..10000 by 10 label "Change per year"
            init level = 1000 label "Level"
            level[t] = level[t-1] + perYear / 12
            """, variable: "level", format: .number)

    // MARK: Climate

    public static let seasonalTemperature = ModelTemplate(
        id: "seasonal-temperature", name: "Seasonal temperature", category: .climate,
        summary: "Monthly mean temperature with seasons and warming", slotName: "Climate", formula: """
            step 1 month
            param mean = 11 range -20..35 by 0.5 label "Yearly mean" as temperature
            param swing = 9 range 0..30 by 0.5 label "Seasonal swing" as temperature
            param warming = 0.03 range 0..0.2 by 0.005 label "Warming per year" as temperature
            param heatwave = 20.2 range 0..45 by 0.1 label "Heatwave above" as temperature
            temp[t] = mean - swing * cos(2 * pi * (month - 1.5) / 12) + warming * days / 365.2425 label "Temperature" as temperature
            when temp > heatwave emit Heatwave
            """, variable: "temp", format: .temperature)

    public static let energyBill = ModelTemplate(
        id: "energy-bill", name: "Energy bill", category: .climate,
        summary: "Heating and cooling costs from a Climate slot's temperature", slotName: "EnergyBill", formula: """
            step 1 month
            param base = 70 range 0..500 by 5 label "Base cost per month" as currency
            param tariff = 1 range 0.5..3 by 0.01 label "Tariff"
            param inflation = 3% range 0%..10% by 0.1% label "Price rise per year"
            bill[t] = (base + 7.5 * max(0, 15 - Climate.temp) + 9 * max(0, Climate.temp - 22)) * tariff * (1 + inflation) ^ (days / 365.2425) label "Monthly bill" as currency
            """, variable: "bill", format: .currency)

    // MARK: Health

    public static let bodyWeight = ModelTemplate(
        id: "body-weight", name: "Body weight", category: .health,
        summary: "Settles where calories eaten match calories burned", slotName: "Weight", formula: """
            step 1 week
            param intake = 2300 range 1200..4500 by 25 label "Calories eaten per day"
            param burnPerKg = 30 range 20..40 by 0.5 label "Calories burned per kg per day"
            init weight = 82 label "Weight in kg"
            weight[t] = weight[t-1] + (intake - burnPerKg * weight[t-1]) * 7 / 7700
            """, variable: "weight", format: .number)

    // MARK: Blank

    /// A small formula to write your own from. Adding it opens the formula editor.
    public static let blankFormula = ModelTemplate(
        id: "blank-formula", name: "Blank formula", category: .blank,
        summary: "A small formula to start your own from", slotName: "Formula", formula: """
            # Write your own model. Each line is checked as you type.
            step 1 month
            param growth = 2% range -20%..20% by 0.1% label "Growth per year"
            init value = 100 label "Value"
            value[t] = value[t-1] * (1 + growth / 12)
            """, variable: "value", format: .number)

    // MARK: Physics

    public static let radioactiveDecay = ModelTemplate(
        id: "radioactive-decay", name: "Radioactive decay", category: .physics,
        summary: "Halves every half-life (caesium-137 to start)", slotName: "Decay", formula: """
            step 1 month
            timeunit year
            param halfLife = 30.1 range 0.5..1000 by 0.1 label "Half-life in years"
            init amount = 1000 label "Amount"
            amount[t] = amount[t-1] * 0.5 ^ (dt / halfLife)
            """, variable: "amount", format: .number)

    public static let batteryCapacity = ModelTemplate(
        id: "battery-capacity", name: "Battery capacity", category: .physics,
        summary: "Loses capacity with every charge, and with age", slotName: "Battery", formula: """
            step 1 week
            param cycles = 5 range 0..21 by 1 label "Charges per week"
            param perCycle = 0.004% range 0%..0.05% by 0.001% label "Lost per charge"
            param perYear = 2% range 0%..10% by 0.1% label "Lost per year with age"
            init capacity = 100% label "Capacity"
            capacity[t] = capacity[t-1] * (1 - perCycle * cycles) * (1 - perYear) ^ (7 / 365.2425)
            when capacity < 80% emit WornOut
            """, variable: "capacity", format: .percent)

    // MARK: Scripts

    /// A Lua script with a loop inside each step.
    public static let predatorPrey = ModelTemplate(
        id: "predator-prey", name: "Predator and prey", category: .growth, kind: .script(.lua),
        summary: "Foxes and rabbits rise and fall in turn", slotName: "Rabbits", formula: """
            -- Foxes and rabbits (Lotka-Volterra), worked out in small steps within each month.
            every "1 month"
            timeunit "year"
            param("birth", 1.1, { range = {0, 3}, by = 0.05, label = "Rabbit births per year" })
            param("predation", 0.004, { range = {0, 0.02}, by = 0.0005, label = "Rabbits eaten per fox per year" })
            param("efficiency", 0.0015, { range = {0, 0.01}, by = 0.0001, label = "Foxes born per rabbit eaten" })
            param("death", 0.6, { range = {0, 3}, by = 0.05, label = "Fox deaths per year" })
            init("rabbits", 400, { label = "Rabbits" })
            init("foxes", 60, { label = "Foxes" })

            function step(s, t)
              local substeps = 30
              local h = t.dt / substeps
              local r, f = s.rabbits, s.foxes
              for _ = 1, substeps do
                local dr = s.birth * r - s.predation * r * f
                local df = s.efficiency * r * f - s.death * f
                r, f = math.max(0, r + h * dr), math.max(0, f + h * df)
              end
              s.rabbits, s.foxes = r, f
            end
            """, variable: "rabbits", format: .number)

    /// A Python script with randomness: the same scenario always draws the same numbers.
    public static let marketSwings = ModelTemplate(
        id: "market-swings", name: "Market with ups and downs", category: .money, kind: .script(.python),
        summary: "Monthly returns drawn at random around an average", slotName: "Portfolio", formula: """
            # An investment whose monthly return is drawn at random, so the line wobbles.
            # The same scenario always draws the same numbers.
            import math

            every("1 month")
            param("growth", "6%", range=("-5%", "15%"), by="0.1%", label="Average growth per year")
            param("volatility", "15%", range=("0%", "40%"), by="0.5%", label="Volatility per year")
            param("contribution", 300, range=(0, 5000), by=50, label="Monthly contribution", as_="currency")
            init("value", 25000, label="Value", as_="currency")
            output("worst", label="Worst month so far", as_="percent")

            def step(s, t):
                monthly = t.normal(s.growth / 12, s.volatility / math.sqrt(12))
                s.value = max(0, s.value * (1 + monthly) + s.contribution)
                s.worst = min(s.worst, monthly)

            @on("deposit")
            def deposit(s, e, t):
                s.value += e.amount

            @on("withdraw")
            def withdraw(s, e, t):
                s.value = max(0, s.value - e.amount)
            """, variable: "value", format: .currency)

    /// A small Lua script to write your own from. Adding it opens the editor.
    public static let blankLua = ModelTemplate(
        id: "blank-lua", name: "Blank Lua script", category: .blank, kind: .script(.lua),
        summary: "A small Lua script to start your own from", slotName: "Script", formula: """
            -- Write your own model in Lua. It's checked as you type.
            every "1 month"
            param("growth", "2%", { range = {"-20%", "20%"}, by = "0.1%", label = "Growth per year" })
            init("value", 100, { label = "Value" })

            function step(s, t)
              s.value = s.value * (1 + s.growth / 12)
            end
            """, variable: "value", format: .number)

    /// A small Python script to write your own from. Adding it opens the editor.
    public static let blankPython = ModelTemplate(
        id: "blank-python", name: "Blank Python script", category: .blank, kind: .script(.python),
        summary: "A small Python script to start your own from", slotName: "Script", formula: """
            # Write your own model in Python. It's checked as you type.
            every("1 month")
            param("growth", "2%", range=("-20%", "20%"), by="0.1%", label="Growth per year")
            init("value", 100, label="Value")

            def step(s, t):
                s.value = s.value * (1 + s.growth / 12)
            """, variable: "value", format: .number)
}
