import Foundation

/// Converts a raw expression string into a flat token stream. Pure; throws
/// `CalcError` on bad input (never raises an Objective-C exception).
enum CalcTokenizer {
    static let maxInputLength = 256
    static let maxTokenCount = 256

    static func tokenize(_ input: String) throws -> [CalcToken] {
        guard input.count <= maxInputLength else { throw CalcError.tooLong }

        var tokens: [CalcToken] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }

            switch c {
            case "+": tokens.append(.plus); i += 1
            case "-": tokens.append(.minus); i += 1
            case "*": tokens.append(.star); i += 1
            case "/": tokens.append(.slash); i += 1
            case "^": tokens.append(.caret); i += 1
            case "%": tokens.append(.percent); i += 1
            case "(": tokens.append(.leftParen); i += 1
            case ")": tokens.append(.rightParen); i += 1
            case ",": tokens.append(.comma); i += 1
            default:
                if c.isNumber || c == "." {
                    var s = ""
                    while i < chars.count, chars[i].isNumber || chars[i] == "." {
                        s.append(chars[i]); i += 1
                    }
                    guard let value = Double(s) else { throw CalcError.malformedNumber(s) }
                    tokens.append(.number(value))
                } else if c.isLetter {
                    var s = ""
                    while i < chars.count, chars[i].isLetter || chars[i].isNumber {
                        s.append(chars[i]); i += 1
                    }
                    tokens.append(.identifier(s.lowercased()))
                } else {
                    throw CalcError.invalidCharacter(c)
                }
            }

            if tokens.count > maxTokenCount { throw CalcError.tooManyTokens }
        }

        guard !tokens.isEmpty else { throw CalcError.empty }
        return tokens
    }
}
