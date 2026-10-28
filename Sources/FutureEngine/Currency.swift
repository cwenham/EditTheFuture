import Foundation

/// The currency money is in, by its ISO 4217 code: "USD", "GBP", "EUR" (docs/DESIGN.md, 15.2).
///
/// It says how amounts are written, in the style usual for it (`regional`). Money one slot reads
/// from a slot in another currency is converted at exchange rates (docs/DESIGN.md, 5.11).
public struct Currency: Hashable, Sendable, CustomStringConvertible {
    /// "GBP".
    public let code: String
    /// The symbol that tells it apart from every other currency: "£", "CA$", or the code for
    /// currencies without one of their own in English: "CHF", "SEK".
    public let symbol: String
    /// The symbol people who use it write: "$" for Canadian dollars, "kr" for Swedish kronor.
    public let localSymbol: String
    /// "British pound".
    public let name: String
    /// "British pounds", for sentences: "Savings is in British pounds".
    public let plural: String
    /// How its amounts are usually written: "1.234,56 €", "CHF 1’234.56", "₹12,34,567".
    public let regional: MoneyWriting
    /// Other words people type after an amount, lowercased: "pounds", "quid".
    let words: [String]

    private init(_ code: String, _ symbol: String, _ name: String, _ plural: String, local: String? = nil,
                 _ numbers: NumberStyle = .commaPoint, first: Bool = true, spaced: Bool? = nil, words extra: [String] = []) {
        self.code = code
        self.symbol = symbol
        let local = local ?? symbol
        localSymbol = local
        self.name = name
        self.plural = plural
        regional = MoneyWriting(numbers: numbers, symbol: local, symbolFirst: first,
                                spaced: spaced ?? (!first || local.last?.isLetter == true))
        // The last word of the name and of the plural: "US dollar" gives "dollar" and "dollars".
        let own = [name, plural].compactMap { $0.split(separator: " ").last.map { $0.lowercased() } }
        var words: [String] = []
        for word in own + extra + [local.lowercased()] where !words.contains(word) { words.append(word) }
        self.words = words
    }

    /// A currency by its code, in any case: "GBP", "eur". nil when it isn't an ISO 4217 code.
    public init?(code: String) {
        let upper = code.trimmingCharacters(in: .whitespaces).uppercased()
        if let known = Self.byCode[upper] {
            self = known
            return
        }
        guard upper.count == 3, upper.allSatisfy({ $0.isASCII && $0.isLetter }), Self.isoCodes.contains(upper) else { return nil }
        let name = Locale(identifier: "en_US").localizedString(forCurrencyCode: upper) ?? upper
        self.init(upper, upper, name, upper)
    }

    public var description: String { code }

    /// What goes before an amount in the app's own style: "£", or "CHF " with a space when the
    /// symbol ends in a letter.
    public var prefix: String { symbol.last?.isLetter == true ? symbol + " " : symbol }

    /// "British pound (£)", for menus. A currency written with its code is just its name.
    public var menuTitle: String { symbol == code ? "\(name) (\(code))" : "\(name) (\(symbol))" }

    /// How its amounts are written in a number style: its own (`regional`) when nil. In another
    /// style, its symbol is the one that tells it apart, placed as that style places symbols.
    public func writing(_ style: NumberStyle?) -> MoneyWriting {
        guard let style else { return regional }
        let first = style.symbolFirst
        return MoneyWriting(numbers: style, symbol: symbol, symbolFirst: first,
                            spaced: !first || symbol.last?.isLetter == true)
    }

    public static func == (a: Currency, b: Currency) -> Bool { a.code == b.code }
    public func hash(into hasher: inout Hasher) { hasher.combine(code) }

    public static let usd = Currency("USD", "$", "US dollar", "US dollars", words: ["us$"])
    public static let eur = Currency("EUR", "€", "Euro", "euros", .pointComma, first: false)
    public static let gbp = Currency("GBP", "£", "British pound", "British pounds", words: ["quid", "sterling"])
    public static let jpy = Currency("JPY", "¥", "Japanese yen", "Japanese yen")

    /// The currencies the app's menus offer, most used first, each with the style usual for it.
    /// Any other ISO 4217 code works too, written with its code.
    public static let common: [Currency] = [
        .usd, .eur, .gbp, .jpy,
        Currency("CNY", "CN¥", "Chinese yuan", "Chinese yuan", local: "¥", words: ["rmb", "renminbi"]),
        Currency("INR", "₹", "Indian rupee", "Indian rupees", .indian),
        Currency("CAD", "CA$", "Canadian dollar", "Canadian dollars", local: "$"),
        Currency("AUD", "A$", "Australian dollar", "Australian dollars", local: "$"),
        Currency("NZD", "NZ$", "New Zealand dollar", "New Zealand dollars", local: "$"),
        Currency("HKD", "HK$", "Hong Kong dollar", "Hong Kong dollars"),
        Currency("SGD", "S$", "Singapore dollar", "Singapore dollars", local: "$"),
        Currency("TWD", "NT$", "New Taiwan dollar", "New Taiwan dollars", local: "$"),
        Currency("CHF", "CHF", "Swiss franc", "Swiss francs", .apostrophePoint),
        Currency("SEK", "SEK", "Swedish krona", "Swedish kronor", local: "kr", .spaceComma, first: false),
        Currency("NOK", "NOK", "Norwegian krone", "Norwegian kroner", local: "kr", .spaceComma, first: false),
        Currency("DKK", "DKK", "Danish krone", "Danish kroner", local: "kr.", .pointComma, first: false),
        Currency("ISK", "ISK", "Icelandic króna", "Icelandic krónur", local: "kr", .pointComma, first: false),
        Currency("PLN", "PLN", "Polish złoty", "Polish złoty", local: "zł", .spaceComma, first: false, words: ["zloty"]),
        Currency("CZK", "CZK", "Czech koruna", "Czech korunas", local: "Kč", .spaceComma, first: false),
        Currency("HUF", "HUF", "Hungarian forint", "Hungarian forints", local: "Ft", .spaceComma, first: false),
        Currency("RON", "RON", "Romanian leu", "Romanian lei", local: "lei", .pointComma, first: false),
        Currency("TRY", "₺", "Turkish lira", "Turkish lira", .pointComma),
        Currency("RUB", "₽", "Russian ruble", "Russian rubles", .spaceComma, first: false, words: ["rouble", "roubles"]),
        Currency("UAH", "₴", "Ukrainian hryvnia", "Ukrainian hryvnias", .spaceComma, first: false),
        Currency("ILS", "₪", "Israeli shekel", "Israeli shekels", first: false),
        Currency("AED", "AED", "UAE dirham", "UAE dirhams"),
        Currency("SAR", "SAR", "Saudi riyal", "Saudi riyals"),
        Currency("EGP", "EGP", "Egyptian pound", "Egyptian pounds", local: "E£"),
        Currency("ZAR", "ZAR", "South African rand", "South African rand", local: "R", .spaceComma, spaced: true),
        Currency("NGN", "₦", "Nigerian naira", "Nigerian naira"),
        Currency("KES", "KES", "Kenyan shilling", "Kenyan shillings", local: "Ksh"),
        Currency("KRW", "₩", "South Korean won", "South Korean won"),
        Currency("THB", "฿", "Thai baht", "Thai baht"),
        Currency("PHP", "₱", "Philippine peso", "Philippine pesos"),
        Currency("VND", "₫", "Vietnamese dong", "Vietnamese dong", .pointComma, first: false),
        Currency("IDR", "IDR", "Indonesian rupiah", "Indonesian rupiah", local: "Rp", .pointComma, spaced: true),
        Currency("MYR", "MYR", "Malaysian ringgit", "Malaysian ringgit", local: "RM", spaced: false),
        Currency("PKR", "PKR", "Pakistani rupee", "Pakistani rupees", local: "Rs"),
        Currency("MXN", "MX$", "Mexican peso", "Mexican pesos", local: "$"),
        Currency("BRL", "R$", "Brazilian real", "Brazilian reais", .pointComma, spaced: true),
        Currency("ARS", "ARS", "Argentine peso", "Argentine pesos", local: "$", .pointComma, spaced: true),
        Currency("CLP", "CLP", "Chilean peso", "Chilean pesos", local: "$", .pointComma),
        Currency("COP", "COP", "Colombian peso", "Colombian pesos", local: "$", .pointComma, spaced: true),
    ]

    static let byCode = Dictionary(uniqueKeysWithValues: common.map { ($0.code, $0) })
    static let isoCodes = Set(Locale.Currency.isoCurrencies.map(\.identifier))

    /// The currency this Mac or device uses, from its region, else US dollars.
    public static var local: Currency {
        Locale.current.currency.flatMap { Currency(code: $0.identifier) } ?? .usd
    }

    /// Whether typed text names this currency: its code, its symbol, a word for it ("pounds"),
    /// or a symbol it ends in, so "$" answers for Canadian dollars (CA$) as well as US ones.
    public func answers(to typed: String) -> Bool {
        let typed = typed.lowercased()
        if typed == code.lowercased() || typed == symbol.lowercased() || words.contains(typed) { return true }
        return !typed.isEmpty && !typed.contains(where: \.isLetter) && symbol.lowercased().hasSuffix(typed)
    }

    /// The currency typed text names: a code ("gbp"), a symbol ("£"), or a word ("euros"). A symbol
    /// or word several currencies share means the first in `common`: "$" is US dollars.
    public static func named(_ text: String) -> Currency? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let currency = Currency(code: text) { return currency }
        return common.first { $0.answers(to: text) }
    }

    /// Takes a currency off typed text: "£1200" → ("1200", "£"), "-$5k" → ("-5k", "$"),
    /// "500euros" → ("500", "euros"), "2.5bnusd" → ("2.5bn", "usd"). The text is lowercased, without
    /// spaces. Symbols go before or after the number; codes and words only after it, so a word
    /// in front, such as a slot's name, is never taken for one. nil when there's no currency.
    public static func split(_ text: String) -> (rest: String, unit: String)? {
        var body = Substring(text)
        var sign = ""
        if let first = body.first, first == "-" || first == "+" {
            sign = String(first)
            body = body.dropFirst()
        }
        func isNumeral(_ character: Character) -> Bool { character.isASCII && (character.isNumber || character == ".") }
        // No currency starts or ends with a digit, so plain numbers, such as every cell of a
        // CSV file of readings, return here.
        if let first = body.first, let last = body.last, isNumeral(first), isNumeral(last) { return nil }
        // A symbol in front: everything before the number, such as "$" or "ca$".
        let lead = body.prefix { !isNumeral($0) && $0 != "-" && $0 != "+" }
        if !lead.isEmpty {
            let unit = String(lead)
            return prefixUnits.contains(unit) ? (sign + body.dropFirst(lead.count), unit) : nil
        }
        // A code, word or symbol after it: the longest ending of what follows the last digit that
        // names a currency, so "2.5bnusd" keeps its "bn".
        let tail = body.suffix(body.reversed().prefix { !isNumeral($0) }.count)
        for start in tail.indices where suffixUnits.contains(String(tail[start...])) {
            return (sign + body[..<start], String(tail[start...]))
        }
        return nil
    }

    /// Every symbol, code and word typed text can name a currency by, lowercased.
    private static let suffixUnits: Set<String> = {
        var units = Set(isoCodes.map { $0.lowercased() })
        for currency in common {
            units.insert(currency.symbol.lowercased())
            units.formUnion(currency.words)  // local symbols among them
        }
        return units
    }()

    /// The ones that can go before a number: symbols, which aren't all letters ("$", "ca$", "€").
    private static let prefixUnits = suffixUnits.filter { $0.contains { !$0.isLetter } }
}

/// How numbers are written: what goes between thousands, and before decimals (docs/UI.md, 5.7).
/// Each currency has one it's usually written in; a scenario can choose one for everything.
public enum NumberStyle: String, Sendable, Hashable, CaseIterable {
    /// 1,234.56: the US, Britain, Ireland, Australia, Japan, China…
    case commaPoint = "comma-point"
    /// 1.234,56: Germany, Spain, Italy, the Netherlands, Brazil, Turkey…
    case pointComma = "point-comma"
    /// 1 234,56: France, Scandinavia, Poland, Czechia, Russia, South Africa…
    case spaceComma = "space-comma"
    /// 1’234.56: Switzerland and Liechtenstein.
    case apostrophePoint = "apostrophe-point"
    /// 12,34,567.89: India, in lakhs and crores.
    case indian

    /// "1,234.56", for menus.
    public var example: String { localize("1,234,567.89") }

    /// What goes before decimals.
    public var decimal: Character { self == .pointComma || self == .spaceComma ? "," : "." }

    /// What goes between thousands: a narrow space that doesn't break for `spaceComma`.
    public var group: String {
        switch self {
        case .commaPoint, .indian: return ","
        case .pointComma: return "."
        case .spaceComma: return "\u{202F}"
        case .apostrophePoint: return "’"
        }
    }

    /// Where a symbol goes when a currency is written in this style rather than its own: first
    /// where decimals follow a point, after the number where they follow a comma.
    public var symbolFirst: Bool { decimal == "." }

    /// "4.5%" or, where decimals follow a comma, "4,5 %".
    public var percentSign: String { decimal == "," ? "\u{00A0}%" : "%" }

    /// A number the app wrote with commas between thousands and a point before decimals
    /// ("1,234.5", "−2.5e18", "250k"), written in this style.
    public func localize(_ text: String) -> String {
        switch self {
        case .commaPoint:
            return text
        case .indian:
            return Self.regroupIndian(text)
        default:
            let group = self.group, decimal = self.decimal
            var out = ""
            out.reserveCapacity(text.utf8.count + 4)
            for character in text {
                switch character {
                case ",": out += group
                case ".": out.append(decimal)
                default: out.append(character)
                }
            }
            return out
        }
    }

    /// Typed text with numbers in this style, with the numbers made plain for reading: thousands
    /// separators taken out and a point before decimals. "1.234,5 €" becomes "1234.5 €" in
    /// `pointComma`. A point in `pointComma` or `spaceComma` is between thousands only when
    /// thousands follow it ("1.234", "12.500"), so "1.5" and "0.045" are read as typed.
    public func normalize(_ text: String) -> String {
        var out = ""
        var run = ""
        func flush() {
            // Separators at the end belong to what follows, such as a sentence's full stop.
            var trailing = ""
            while let last = run.last, !last.isNumber { trailing.insert(last, at: trailing.startIndex); run.removeLast() }
            out += plain(run) + trailing
            run = ""
        }
        var previous: Character?
        for character in text {
            let digit = character.isASCII && character.isNumber
            if digit || (!run.isEmpty && Self.separators.contains(character)) {
                run.append(character)
            } else if (character == "." || character == ","), previous.map({ !($0.isASCII && $0.isNumber) }) ?? true, run.isEmpty {
                // ".5" or ",5": a number starting with its decimals.
                run.append(character)
            } else {
                if !run.isEmpty { flush() }
                out.append(character)
            }
            previous = character
        }
        if !run.isEmpty { flush() }
        return out
    }

    /// Characters that can be inside a number: separators of every style.
    private static let separators: Set<Character> = [".", ",", "’", "'", " ", "\u{00A0}", "\u{202F}"]

    /// One number's digits and separators, made plain.
    private func plain(_ run: String) -> String {
        var text = run.filter { !"’' \u{00A0}\u{202F}".contains($0) }
        if decimal == "," {
            if let comma = text.lastIndex(of: ",") {
                let whole = text[..<comma].filter { $0 != "." && $0 != "," }
                return whole + "." + text[text.index(after: comma)...]
            }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            let thousands = parts.count > 1 && (1...3).contains(parts[0].count) && parts[0].first != "0"
                && parts.dropFirst().allSatisfy { $0.count == 3 }
            if thousands { return text.filter { $0 != "." } }
            if parts.count > 2, let point = text.lastIndex(of: ".") {
                return text[..<point].filter { $0 != "." } + text[point...]
            }
            return text
        }
        text.removeAll { $0 == "," }
        return text
    }

    /// "1,234,567.89" → "12,34,567.89": thousands, then hundreds of thousands (lakhs) in twos.
    private static func regroupIndian(_ text: String) -> String {
        var out = ""
        var digits = ""
        func flush() {
            guard digits.count > 3 else { out += digits; digits = ""; return }
            let tail = digits.suffix(3)
            var head = Array(digits.dropLast(3))
            var groups: [String] = []
            while !head.isEmpty {
                groups.insert(String(head.suffix(2)), at: 0)
                head.removeLast(min(2, head.count))
            }
            out += groups.joined(separator: ",") + "," + tail
            digits = ""
        }
        var inDecimals = false
        for character in text {
            if character.isASCII && character.isNumber && !inDecimals {
                digits.append(character)
            } else if character == ",", !digits.isEmpty, !inDecimals {
                continue
            } else {
                flush()
                inDecimals = character == "." || (inDecimals && character.isASCII && character.isNumber)
                out.append(character)
            }
        }
        flush()
        return out
    }
}

/// How a currency's amounts are written: the number style, the symbol, and where it goes.
public struct MoneyWriting: Hashable, Sendable {
    public var numbers: NumberStyle
    /// "€", "kr", "CA$".
    public var symbol: String
    /// Whether the symbol goes before the number: "£1,234", not "1.234 €".
    public var symbolFirst: Bool
    /// Whether a space that doesn't break goes between them: "CHF 1’234", "1 234 kr".
    public var spaced: Bool

    public init(numbers: NumberStyle, symbol: String, symbolFirst: Bool, spaced: Bool) {
        self.numbers = numbers
        self.symbol = symbol
        self.symbolFirst = symbolFirst
        self.spaced = spaced
    }

    /// The app's own style before regional styles: "$1,234", "CHF 1,234".
    public static func plain(_ currency: Currency) -> MoneyWriting { currency.writing(.commaPoint) }

    /// An amount whose number is already written in `numbers`: "£1,234", "−1.234 €".
    public func amount(_ number: String, negative: Bool = false) -> String {
        let sign = negative ? "−" : ""
        let gap = spaced ? "\u{00A0}" : ""
        return symbolFirst ? sign + symbol + gap + number : sign + number + gap + symbol
    }

    /// The same with another symbol, such as the one that tells the currency apart.
    public func withSymbol(_ symbol: String) -> MoneyWriting {
        var copy = self
        copy.symbol = symbol
        if symbolFirst, symbol.last?.isLetter == true { copy.spaced = true }
        return copy
    }
}
