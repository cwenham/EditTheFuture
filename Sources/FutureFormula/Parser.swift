import FutureEngine

/// Turns formula source into a `Program`. One statement per line; see docs/DESIGN.md, section 6.2.
struct Parser {
    private let tokens: [Token]
    private var position = 0
    private var program = Program()
    private var inHandler = false

    static func parse(_ source: String) throws -> Program {
        var parser = Parser(tokens: try Lexer.tokenize(source))
        return try parser.parseProgram()
    }

    private init(tokens: [Token]) {
        self.tokens = tokens
    }

    // MARK: Statements

    private mutating func parseProgram() throws -> Program {
        while true {
            while current.kind == .newline { advance() }
            if current.kind == .end { break }
            try parseStatement()
            guard current.kind == .newline || current.kind == .end else {
                throw syntax("Expected the end of the line, found \(describe(current)).")
            }
        }
        return program
    }

    private mutating func parseStatement() throws {
        let line = current.line
        guard case .identifier(let word) = current.kind else {
            throw syntax("Expected a statement, found \(describe(current)).")
        }
        switch word {
        case "step":
            advance()
            program.stepRate = try parseRate()
        case "timeunit":
            advance()
            program.timeUnit = try parseUnit(count: 1)
        case "param":
            advance()
            let name = try expectIdentifier()
            try expectSymbol("=")
            program.params.append(Assignment(name: name, expr: try parseExpression(), line: line))
        case "init":
            advance()
            let name = try expectIdentifier()
            try expectSymbol("=")
            program.inits.append(Assignment(name: name, expr: try parseExpression(), line: line))
        case "when":
            advance()
            let condition = try parseExpression()
            try expectKeyword("emit")
            let kind = try expectIdentifier()
            program.triggers.append(Trigger(condition: condition, kind: kind, line: line))
        case "on":
            advance()
            try parseHandler(line: line)
        default:
            if word.count > 1, word.hasPrefix("d"), isSymbol("/", at: 1), isIdentifier("dt", at: 2), isSymbol("=", at: 3) {
                advance(4)
                program.odes.append(Assignment(name: String(word.dropFirst()), expr: try parseExpression(), line: line))
            } else {
                advance()
                if isSymbol("[") {
                    advance()
                    guard isIdentifier("t") else { throw syntax("A definition looks like \(word)[t] = …") }
                    advance()
                    try expectSymbol("]")
                }
                try expectSymbol("=")
                program.definitions.append(Assignment(name: word, expr: try parseExpression(), line: line))
            }
        }
    }

    private mutating func parseRate() throws -> StepRate {
        var count = 1
        if case .number(let value) = current.kind {
            // The upper limit also keeps the conversion to Int from trapping on numbers like 1e30.
            guard value >= 1, value <= 1_000_000, value == value.rounded() else {
                throw syntax("A step must be a whole number of units, from 1 to 1,000,000.")
            }
            count = Int(value)
            advance()
        }
        return try parseUnit(count: count)
    }

    private mutating func parseUnit(count: Int) throws -> StepRate {
        let word = try expectIdentifier()
        switch word {
        case "second", "seconds", "sec": return .seconds(count)
        case "minute", "minutes", "min": return .minutes(count)
        case "hour", "hours": return .hours(count)
        case "day", "days": return .days(count)
        case "week", "weeks": return .weeks(count)
        case "month", "months": return .months(count)
        case "quarter", "quarters": return .quarters(count)
        case "year", "years": return .years(count)
        default: throw syntax("\(word) isn't a time unit. Use second, minute, hour, day, week, month, quarter or year.")
        }
    }

    private mutating func parseHandler(line: Int) throws {
        let first = try expectIdentifier()
        var origin: String?
        var kind = first
        if isSymbol(".") {
            advance()
            origin = first
            kind = try expectIdentifier()
        }
        var timing = Timing.sameStep
        if try parseLagSuffix() {
            guard origin != nil else {
                throw syntax("Only events from other slots can be read from the previous step.")
            }
            timing = .previousStep
        }
        try expectSymbol(":")

        inHandler = true
        defer { inHandler = false }
        var actions: [Action] = []
        repeat {
            let target = try expectIdentifier()
            guard case .symbol(let text) = current.kind, let op = AssignmentOperator(rawValue: text) else {
                throw syntax("Expected =, +=, -=, *= or /= after \(target).")
            }
            advance()
            actions.append(Action(target: target, op: op, expr: try parseExpression(), line: line))
        } while consumeSymbol(";")
        program.handlers.append(Handler(origin: origin, kind: kind, timing: timing, actions: actions, line: line))
    }

    // MARK: Expressions

    private mutating func parseExpression() throws -> Expr {
        try parseOr()
    }

    private mutating func parseOr() throws -> Expr {
        var left = try parseAnd()
        while isIdentifier("or") {
            advance()
            left = .binary(.or, left, try parseAnd())
        }
        return left
    }

    private mutating func parseAnd() throws -> Expr {
        var left = try parseNot()
        while isIdentifier("and") {
            advance()
            left = .binary(.and, left, try parseNot())
        }
        return left
    }

    private mutating func parseNot() throws -> Expr {
        if isIdentifier("not") {
            advance()
            return .unary(.not, try parseNot())
        }
        return try parseComparison()
    }

    private mutating func parseComparison() throws -> Expr {
        let left = try parseAdditive()
        if case .symbol(let text) = current.kind,
           let op = BinaryOperator(rawValue: text),
           [.less, .lessOrEqual, .greater, .greaterOrEqual, .equal, .notEqual].contains(op) {
            advance()
            return .binary(op, left, try parseAdditive())
        }
        return left
    }

    private mutating func parseAdditive() throws -> Expr {
        var left = try parseMultiplicative()
        while true {
            if consumeSymbol("+") {
                left = .binary(.add, left, try parseMultiplicative())
            } else if consumeSymbol("-") {
                left = .binary(.subtract, left, try parseMultiplicative())
            } else {
                return left
            }
        }
    }

    private mutating func parseMultiplicative() throws -> Expr {
        var left = try parseUnary()
        while true {
            if consumeSymbol("*") {
                left = .binary(.multiply, left, try parseUnary())
            } else if consumeSymbol("/") {
                left = .binary(.divide, left, try parseUnary())
            } else {
                return left
            }
        }
    }

    private mutating func parseUnary() throws -> Expr {
        if consumeSymbol("-") { return .unary(.negate, try parseUnary()) }
        if consumeSymbol("+") { return try parseUnary() }
        return try parsePower()
    }

    /// `^` binds tighter than unary minus and is right-associative: -x^2 is -(x^2), 2^3^2 is 2^9.
    private mutating func parsePower() throws -> Expr {
        let base = try parsePrimary()
        if consumeSymbol("^") {
            return .binary(.power, base, try parseUnary())
        }
        return base
    }

    private mutating func parsePrimary() throws -> Expr {
        switch current.kind {
        case .number(var value):
            advance()
            if consumeSymbol("%") { value /= 100 }
            return .number(value)
        case .symbol("("):
            advance()
            let inner = try parseExpression()
            try expectSymbol(")")
            return inner
        case .identifier(let name):
            advance()
            if consumeSymbol("(") {
                var arguments: [Expr] = []
                if !isSymbol(")") {
                    repeat { arguments.append(try parseExpression()) } while consumeSymbol(",")
                }
                try expectSymbol(")")
                return .call(name, arguments)
            }
            var parts = [name]
            while consumeSymbol(".") {
                parts.append(try expectIdentifier())
            }
            let lagged = try parseLagSuffix()
            return try reference(parts, lagged: lagged)
        default:
            throw syntax("Expected a value, found \(describe(current)).")
        }
    }

    private mutating func reference(_ parts: [String], lagged: Bool) throws -> Expr {
        if parts.count == 1 { return .name(parts[0], lagged: lagged) }
        if parts[0] == "event" {
            guard inHandler else { throw syntax("event.\(parts[1]) can only be used inside an on handler.") }
            guard parts.count == 2, !lagged else { throw syntax("Use event.name to read a value of the event.") }
            return .eventField(parts[1])
        }
        guard parts.count <= 3 else { throw syntax("\(parts.joined(separator: ".")) has too many parts.") }
        var resampling = Resampling.hold
        if parts.count == 3 {
            guard let rule = Resampling(rawValue: parts[2]) else {
                throw syntax("\(parts[2]) isn't a resampling rule. Use hold, mean, sum, min or max.")
            }
            resampling = rule
        }
        let reference = Reference(slot: parts[0], variable: parts[1], resampling: resampling,
                                  timing: lagged ? .previousStep : .sameStep)
        program.references[reference.text] = reference
        return .input(reference.text)
    }

    /// Parses an optional `[t]` or `[t-1]`. Returns true for `[t-1]`.
    private mutating func parseLagSuffix() throws -> Bool {
        guard consumeSymbol("[") else { return false }
        guard isIdentifier("t") else { throw syntax("Only [t] and [t-1] are supported.") }
        advance()
        var lagged = false
        if consumeSymbol("-") {
            guard case .number(1) = current.kind else { throw syntax("Only [t] and [t-1] are supported.") }
            advance()
            lagged = true
        }
        try expectSymbol("]")
        return lagged
    }

    // MARK: Token helpers

    private var current: Token { tokens[position] }

    private mutating func advance(_ count: Int = 1) {
        position = min(position + count, tokens.count - 1)
    }

    private func token(at offset: Int) -> Token {
        tokens[min(position + offset, tokens.count - 1)]
    }

    private func isSymbol(_ symbol: String, at offset: Int = 0) -> Bool {
        token(at: offset).kind == .symbol(symbol)
    }

    private func isIdentifier(_ name: String, at offset: Int = 0) -> Bool {
        token(at: offset).kind == .identifier(name)
    }

    private mutating func consumeSymbol(_ symbol: String) -> Bool {
        guard isSymbol(symbol) else { return false }
        advance()
        return true
    }

    private mutating func expectSymbol(_ symbol: String) throws {
        guard consumeSymbol(symbol) else { throw syntax("Expected \"\(symbol)\", found \(describe(current)).") }
    }

    private mutating func expectKeyword(_ word: String) throws {
        guard isIdentifier(word) else { throw syntax("Expected \"\(word)\", found \(describe(current)).") }
        advance()
    }

    private mutating func expectIdentifier() throws -> String {
        guard case .identifier(let name) = current.kind else {
            throw syntax("Expected a name, found \(describe(current)).")
        }
        advance()
        return name
    }

    private func syntax(_ message: String) -> FormulaError {
        .syntax(line: current.line, message: message)
    }

    private func describe(_ token: Token) -> String {
        switch token.kind {
        case .number(let value): return "\(value)"
        case .identifier(let name): return "\"\(name)\""
        case .symbol(let symbol): return "\"\(symbol)\""
        case .newline: return "the end of the line"
        case .end: return "the end of the formula"
        }
    }
}
