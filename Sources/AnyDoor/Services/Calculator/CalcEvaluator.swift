import Foundation

/// Recursive-descent parser + evaluator over a `CalcToken` stream.
///
/// Grammar (low → high precedence):
///   expression := term (('+' | '-') term)*
///   term       := unary (('*' | '/') unary)*
///   unary      := ('-' | '+') unary | power
///   power      := primary ('^' unary)?            // right-assoc; exponent may be unary
///   primary    := number ['%'] | identifier ['(' args ')'] | '(' expression ')'
///   args       := expression (',' expression)*
///
/// Percent binds tightest, and only to a number literal, so `(1+2)%` is invalid
/// (the stray `%` is left over and the final all-consumed check fails).
struct CalcEvaluator {
    static let maxDepth = 64

    private let tokens: [CalcToken]
    private var pos = 0
    private var depth = 0

    private init(tokens: [CalcToken]) { self.tokens = tokens }

    /// Evaluate a token stream to a finite `Double`, or throw `CalcError`.
    static func evaluate(_ tokens: [CalcToken]) throws -> Double {
        var parser = CalcEvaluator(tokens: tokens)
        let value = try parser.parseExpression()
        guard parser.pos == parser.tokens.count else { throw CalcError.unexpectedToken }
        guard value.isFinite else { throw CalcError.notFinite }
        return value
    }

    private var current: CalcToken? { pos < tokens.count ? tokens[pos] : nil }
    private mutating func advance() { pos += 1 }

    private mutating func enter() throws {
        depth += 1
        if depth > Self.maxDepth { throw CalcError.tooDeep }
    }
    private mutating func leave() { depth -= 1 }

    private mutating func parseExpression() throws -> Double {
        try enter(); defer { leave() }
        var value = try parseTerm()
        while let t = current, t == .plus || t == .minus {
            advance()
            let rhs = try parseTerm()
            value = (t == .plus) ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseUnary()
        while let t = current, t == .star || t == .slash {
            advance()
            let rhs = try parseUnary()
            value = (t == .star) ? value * rhs : value / rhs
        }
        return value
    }

    private mutating func parseUnary() throws -> Double {
        if current == .minus { advance(); return -(try parseUnary()) }
        if current == .plus { advance(); return try parseUnary() }
        return try parsePower()
    }

    private mutating func parsePower() throws -> Double {
        let base = try parsePrimary()
        if current == .caret {
            advance()
            let exponent = try parseUnary()
            return pow(base, exponent)
        }
        return base
    }

    private mutating func parsePrimary() throws -> Double {
        try enter(); defer { leave() }
        guard let t = current else { throw CalcError.unexpectedEnd }
        switch t {
        case .number(let v):
            advance()
            if current == .percent { advance(); return v / 100 }
            return v
        case .leftParen:
            advance()
            let inner = try parseExpression()
            guard current == .rightParen else { throw CalcError.unexpectedToken }
            advance()
            return inner
        case .identifier(let name):
            advance()
            return try resolveIdentifier(name)
        default:
            throw CalcError.unexpectedToken
        }
    }

    private mutating func resolveIdentifier(_ name: String) throws -> Double {
        // A constant only when NOT followed by a call paren.
        guard current == .leftParen else {
            if let constant = CalcFunctions.constants[name] { return constant }
            throw CalcError.unknownIdentifier(name)
        }
        advance() // consume '('
        var args: [Double] = []
        if current != .rightParen {
            args.append(try parseExpression())
            while current == .comma {
                advance()
                args.append(try parseExpression())
            }
        }
        guard current == .rightParen else { throw CalcError.unexpectedToken }
        advance()
        return try CalcFunctions.apply(name, args)
    }
}
