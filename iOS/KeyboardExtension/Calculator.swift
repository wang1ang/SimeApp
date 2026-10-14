import Foundation

/// Inline arithmetic for the association bar: `1+1` → shows `1+1=2`,
/// inserts `=2`. Uses Decimal so `0.1+0.2` yields `0.3`.
struct CalculatorSuggestion: Equatable {
    let display: String
    let insert: String
}

enum Calculator {
    private static let maxLength = 64
    private static let fractionDigits: Int16 = 10

    private static let operators: [Character: Character] = [
        "+": "+", "＋": "+", "-": "-", "－": "-", "−": "-",
        "*": "*", "×": "*", "＊": "*", "/": "/", "÷": "/", "／": "/",
    ]
    private static let openParens: Set<Character> = ["(", "（"]
    private static let closeParens: Set<Character> = [")", "）"]

    private static func isExpressionChar(_ c: Character) -> Bool {
        c.isASCII && c.isNumber || c == "." || operators[c] != nil
            || openParens.contains(c) || closeParens.contains(c)
    }

    /// Evaluates the arithmetic expression ending at the cursor. A trailing
    /// `=` means the user already typed it, so only the result is inserted.
    static func suggestion(forContext context: String) -> CalculatorSuggestion? {
        var text = Substring(context.suffix(maxLength + 1))
        let endsWithEquals = text.last == "=" || text.last == "＝"
        if endsWithEquals { text = text.dropLast() }
        var expr = String(text.reversed().prefix { isExpressionChar($0) }.reversed())
        // A leading binary operator or `)` belongs to preceding prose.
        while let first = expr.first,
              closeParens.contains(first) || (operators[first] != nil && operators[first] != "-") {
            expr.removeFirst()
        }
        guard !expr.isEmpty, expr.count <= maxLength,
              let value = evaluate(expr) else { return nil }
        let result = format(value)
        return CalculatorSuggestion(display: expr + "=" + result,
                                    insert: endsWithEquals ? result : "=" + result)
    }

    /// Nil unless `expr` is a complete expression with at least one binary
    /// operator (a bare number or `-5` is not a calculation).
    static func evaluate(_ expr: String) -> Decimal? {
        var parser = Parser(chars: Array(expr))
        guard let value = parser.parseExpression(), parser.atEnd,
              parser.binaryOperatorCount > 0, !value.isNaN else { return nil }
        return value
    }

    static func format(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, Int(fractionDigits), .plain)
        if rounded.isZero { rounded = 0 } // avoid "-0"
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        var binaryOperatorCount = 0

        var atEnd: Bool { index == chars.count }

        private func peekOperator() -> Character? {
            index < chars.count ? Calculator.operators[chars[index]] : nil
        }

        mutating func parseExpression() -> Decimal? {
            guard var lhs = parseTerm() else { return nil }
            while let op = peekOperator(), op == "+" || op == "-" {
                index += 1
                guard let rhs = parseTerm() else { return nil }
                binaryOperatorCount += 1
                lhs = op == "+" ? lhs + rhs : lhs - rhs
            }
            return lhs
        }

        mutating func parseTerm() -> Decimal? {
            guard var lhs = parseFactor() else { return nil }
            while let op = peekOperator(), op == "*" || op == "/" {
                index += 1
                guard let rhs = parseFactor() else { return nil }
                binaryOperatorCount += 1
                if op == "*" {
                    lhs *= rhs
                } else {
                    guard !rhs.isZero else { return nil }
                    lhs /= rhs
                }
            }
            return lhs
        }

        mutating func parseFactor() -> Decimal? {
            guard index < chars.count else { return nil }
            if peekOperator() == "-" {
                index += 1
                return parseFactor().map { -$0 }
            }
            if Calculator.openParens.contains(chars[index]) {
                index += 1
                guard let value = parseExpression(), index < chars.count,
                      Calculator.closeParens.contains(chars[index]) else { return nil }
                index += 1
                return value
            }
            return parseNumber()
        }

        mutating func parseNumber() -> Decimal? {
            let start = index
            var sawDot = false
            while index < chars.count {
                let c = chars[index]
                if c == "." {
                    guard !sawDot else { return nil }
                    sawDot = true
                } else if !(c.isASCII && c.isNumber) {
                    break
                }
                index += 1
            }
            let token = String(chars[start..<index])
            guard !token.isEmpty, token.first != ".", token.last != "." else { return nil }
            // `05`-style operands are dates or codes (2024-05-01), not math.
            if token.count > 1, token.first == "0", token.dropFirst().first != "." { return nil }
            return Decimal(string: token, locale: Locale(identifier: "en_US_POSIX"))
        }
    }
}
