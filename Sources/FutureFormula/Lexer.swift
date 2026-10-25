import Foundation

enum TokenKind: Equatable {
    case number(Double)
    case identifier(String)
    case symbol(String)
    /// `"Interest rate"`, for labels.
    case string(String)
    case newline
    case end
}

struct Token: Equatable {
    let kind: TokenKind
    let line: Int
}

enum Lexer {
    private static let twoCharacterSymbols: Set<String> = ["+=", "-=", "*=", "/=", "<=", ">=", "==", "!=", ".."]
    private static let oneCharacterSymbols: Set<Character> = ["+", "-", "*", "/", "^", "(", ")", "[", "]", ",", ".", ":", "=", "<", ">", "%", ";"]

    static func tokenize(_ source: String) throws -> [Token] {
        let characters = Array(source)
        var tokens: [Token] = []
        var index = 0
        var line = 1

        func peek(_ offset: Int = 0) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        while let character = peek() {
            if character == "\n" {
                if tokens.last?.kind != .newline { tokens.append(Token(kind: .newline, line: line)) }
                line += 1
                index += 1
            } else if character.isWhitespace {
                index += 1
            } else if character == "#" || (character == "/" && peek(1) == "/") {
                while let next = peek(), next != "\n" { index += 1 }
            } else if character == "\"" {
                index += 1
                var text = ""
                while let next = peek(), next != "\"" {
                    guard next != "\n" else { throw FormulaError.syntax(line: line, message: "This text needs a closing \".") }
                    text.append(next)
                    index += 1
                }
                guard peek() == "\"" else { throw FormulaError.syntax(line: line, message: "This text needs a closing \".") }
                index += 1
                tokens.append(Token(kind: .string(text), line: line))
            } else if character.isNumber {
                tokens.append(Token(kind: .number(try readNumber(characters, &index, line: line)), line: line))
            } else if character.isLetter || character == "_" {
                var name = ""
                while let next = peek(), next.isLetter || next.isNumber || next == "_" {
                    name.append(next)
                    index += 1
                }
                tokens.append(Token(kind: .identifier(name), line: line))
            } else if let next = peek(1), twoCharacterSymbols.contains(String([character, next])) {
                tokens.append(Token(kind: .symbol(String([character, next])), line: line))
                index += 2
            } else if oneCharacterSymbols.contains(character) {
                tokens.append(Token(kind: .symbol(String(character)), line: line))
                index += 1
            } else {
                throw FormulaError.syntax(line: line, message: "Unexpected character \"\(character)\".")
            }
        }
        tokens.append(Token(kind: .end, line: line))
        return tokens
    }

    private static func readNumber(_ characters: [Character], _ index: inout Int, line: Int) throws -> Double {
        var text = ""
        func peek(_ offset: Int = 0) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }
        func readDigits() {
            while let next = peek(), next.isNumber || next == "_" {
                if next != "_" { text.append(next) }
                index += 1
            }
        }
        readDigits()
        if peek() == ".", let after = peek(1), after.isNumber {
            text.append(".")
            index += 1
            readDigits()
        }
        if let e = peek(), e == "e" || e == "E" {
            let sign = peek(1)
            let hasSign = sign == "+" || sign == "-"
            if let digit = peek(hasSign ? 2 : 1), digit.isNumber {
                text.append("e")
                if hasSign { text.append(sign!) }
                index += hasSign ? 2 : 1
                readDigits()
            }
        }
        guard let value = Double(text) else {
            throw FormulaError.syntax(line: line, message: "\(text) isn't a valid number.")
        }
        return value
    }
}
