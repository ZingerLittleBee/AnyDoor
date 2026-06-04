import XCTest
@testable import AnyDoor

final class CalculatorTests: XCTestCase {

    // MARK: - Tokenizer

    func test_tokenize_numbersOperatorsAndParens() throws {
        let tokens = try CalcTokenizer.tokenize("1 + 2.5 * (3)")
        XCTAssertEqual(tokens, [
            .number(1), .plus, .number(2.5), .star, .leftParen, .number(3), .rightParen
        ])
    }

    func test_tokenize_identifiersWithDigitsAndComma() throws {
        let tokens = try CalcTokenizer.tokenize("log2(8), POW(2,3)")
        XCTAssertEqual(tokens, [
            .identifier("log2"), .leftParen, .number(8), .rightParen, .comma,
            .identifier("pow"), .leftParen, .number(2), .comma, .number(3), .rightParen
        ])
    }

    func test_tokenize_percentAndCaret() throws {
        XCTAssertEqual(try CalcTokenizer.tokenize("8%^2"), [.number(8), .percent, .caret, .number(2)])
    }

    func test_tokenize_emptyThrows() {
        XCTAssertThrowsError(try CalcTokenizer.tokenize("   "))
    }

    func test_tokenize_invalidCharacterThrows() {
        XCTAssertThrowsError(try CalcTokenizer.tokenize("1 @ 2"))
    }

    func test_tokenize_malformedNumberThrows() {
        XCTAssertThrowsError(try CalcTokenizer.tokenize("1.2.3"))
    }

    func test_tokenize_tooLongThrows() {
        let long = String(repeating: "1", count: 300)
        XCTAssertThrowsError(try CalcTokenizer.tokenize(long))
    }
}
