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

    // MARK: - Functions table

    func test_functions_constants() {
        XCTAssertEqual(CalcFunctions.constants["pi"]!, Double.pi, accuracy: 1e-12)
        XCTAssertEqual(CalcFunctions.constants["e"]!, 2.718281828459045, accuracy: 1e-12)
    }

    func test_functions_unaryApply() throws {
        XCTAssertEqual(try CalcFunctions.apply("sqrt", [9]), 3, accuracy: 1e-12)
        XCTAssertEqual(try CalcFunctions.apply("ln", [2.718281828459045]), 1, accuracy: 1e-9)
        XCTAssertEqual(try CalcFunctions.apply("log", [1000]), 3, accuracy: 1e-12)
        XCTAssertEqual(try CalcFunctions.apply("log10", [1000]), 3, accuracy: 1e-12)
    }

    func test_functions_binaryApply() throws {
        XCTAssertEqual(try CalcFunctions.apply("pow", [2, 10]), 1024, accuracy: 1e-9)
        XCTAssertEqual(try CalcFunctions.apply("min", [3, 5]), 3)
        XCTAssertEqual(try CalcFunctions.apply("max", [3, 5]), 5)
    }

    func test_functions_unknownAndArityThrow() {
        XCTAssertThrowsError(try CalcFunctions.apply("nope", [1]))
        XCTAssertThrowsError(try CalcFunctions.apply("pow", [2]))      // wrong arity
        XCTAssertThrowsError(try CalcFunctions.apply("sqrt", [1, 2]))  // wrong arity
    }

    // MARK: - Evaluator

    private func eval(_ s: String) throws -> Double {
        try CalcEvaluator.evaluate(try CalcTokenizer.tokenize(s))
    }

    func test_eval_precedenceAndAssociativity() throws {
        XCTAssertEqual(try eval("2+3*4"), 14, accuracy: 1e-12)
        XCTAssertEqual(try eval("2^3^2"), 512, accuracy: 1e-9)   // right-assoc
        XCTAssertEqual(try eval("-2^2"), -4, accuracy: 1e-12)
        XCTAssertEqual(try eval("2^-2"), 0.25, accuracy: 1e-12)
        XCTAssertEqual(try eval("(-2)^2"), 4, accuracy: 1e-12)
    }

    func test_eval_parensAndUnary() throws {
        XCTAssertEqual(try eval("-(3+4)"), -7, accuracy: 1e-12)
        XCTAssertEqual(try eval("2*(3+4)"), 14, accuracy: 1e-12)
    }

    func test_eval_functionsAndConstants() throws {
        XCTAssertEqual(try eval("sqrt(2)"), 1.4142135623, accuracy: 1e-9)
        XCTAssertEqual(try eval("sin(pi/2)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try eval("ln(e)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try eval("pow(2,10)"), 1024, accuracy: 1e-9)
        XCTAssertEqual(try eval("min(3,5)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try eval("max(3,5)"), 5, accuracy: 1e-12)
    }

    func test_eval_percentLiteral() throws {
        XCTAssertEqual(try eval("50%"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try eval("1234*8%"), 98.72, accuracy: 1e-9)
        XCTAssertEqual(try eval("200+10%"), 200.1, accuracy: 1e-9)
    }

    func test_eval_invalidInputsThrow() {
        XCTAssertThrowsError(try eval("1/0"))       // +Inf → notFinite
        XCTAssertThrowsError(try eval("(1+2)%"))    // percent only follows a number literal
        XCTAssertThrowsError(try eval("pow(2)"))    // wrong arity
        XCTAssertThrowsError(try eval("()"))
        XCTAssertThrowsError(try eval("2 ** abc"))
    }

    func test_eval_tooDeepThrows() {
        let deep = String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200)
        XCTAssertThrowsError(try eval(deep))
    }

    // MARK: - Facade: detection

    func test_facade_bareNumberAndConstantsAreNotDetected() {
        XCTAssertNil(Calculator.evaluate(query: "8080"))
        XCTAssertNil(Calculator.evaluate(query: "5"))
        XCTAssertNil(Calculator.evaluate(query: "pi"))
        XCTAssertNil(Calculator.evaluate(query: "e"))
        XCTAssertNil(Calculator.evaluate(query: "-5"))   // bare negative number
    }

    func test_facade_forcePrefix() throws {
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "=8080")).copyText, "8080")
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "=pi")).value, Double.pi, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "=5")).copyText, "5")
    }

    func test_facade_autoDetectExpressions() throws {
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "1+2")).copyText, "3")
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "   2 + 2  ")).copyText, "4")
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "pi/2")).value, Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "2*e")).value, 2 * M_E, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "sqrt(2)")).value, 1.41421356, accuracy: 1e-7)
    }

    func test_facade_failuresReturnNil() {
        XCTAssertNil(Calculator.evaluate(query: "1 +"))
        XCTAssertNil(Calculator.evaluate(query: "sqrt("))
        XCTAssertNil(Calculator.evaluate(query: "1/0"))
        XCTAssertNil(Calculator.evaluate(query: ""))
        XCTAssertNil(Calculator.evaluate(query: "="))
    }

    // MARK: - Facade: formatting (copyText is locale-independent)

    func test_facade_copyTextFormatting() throws {
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "2+2")).copyText, "4")        // integer, no ".0"
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "1/4")).copyText, "0.25")
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "1000*1000")).copyText, "1000000") // no grouping
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "10/4")).copyText, "2.5")     // trailing zero trimmed
    }
}
