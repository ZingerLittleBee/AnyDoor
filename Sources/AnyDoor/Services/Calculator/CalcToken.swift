import Foundation

/// A lexical token produced by `CalcTokenizer`.
enum CalcToken: Equatable {
    case number(Double)
    case identifier(String)   // function or constant name, already lowercased
    case plus
    case minus
    case star
    case slash
    case caret
    case percent
    case leftParen
    case rightParen
    case comma
}

/// Internal failure reason. The public `Calculator` facade maps any error to
/// `nil`, so the palette simply shows no calculator section on failure.
enum CalcError: Error, Equatable {
    case empty
    case tooLong
    case tooManyTokens
    case invalidCharacter(Character)
    case malformedNumber(String)
    case unexpectedToken
    case unexpectedEnd
    case unknownIdentifier(String)
    case wrongArity(String)
    case tooDeep
    case notFinite
}
