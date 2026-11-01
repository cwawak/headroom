import XCTest
@testable import Headroom

final class AppDelegatePercentParserTests: XCTestCase {

    // MARK: - Valid Percentage Parsing Tests

    func testPercentParsingStandardIntegerStrings() {
        XCTAssertEqual(AppDelegate.percent(from: "54"), 54.0)
        XCTAssertEqual(AppDelegate.percent(from: "1"), 1.0)
        XCTAssertEqual(AppDelegate.percent(from: "50"), 50.0)
        XCTAssertEqual(AppDelegate.percent(from: "99"), 99.0)
        XCTAssertEqual(AppDelegate.percent(from: "100"), 100.0)
    }

    func testPercentParsingTrailingPercentSign() {
        XCTAssertEqual(AppDelegate.percent(from: "54%"), 54.0)
        XCTAssertEqual(AppDelegate.percent(from: "1%"), 1.0)
        XCTAssertEqual(AppDelegate.percent(from: "100%"), 100.0)
    }

    func testPercentParsingWhitespaceAndPadding() {
        XCTAssertEqual(AppDelegate.percent(from: " 54 % "), 54.0)
        XCTAssertEqual(AppDelegate.percent(from: "   54%"), 54.0)
        XCTAssertEqual(AppDelegate.percent(from: "54%   "), 54.0)
        XCTAssertEqual(AppDelegate.percent(from: " 100 % "), 100.0)
        XCTAssertEqual(AppDelegate.percent(from: "%54"), 54.0)
        XCTAssertEqual(AppDelegate.percent(from: " % 54 "), 54.0)
    }

    func testPercentParsingDecimals() throws {
        XCTAssertEqual(try XCTUnwrap(AppDelegate.percent(from: "0.1")), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(AppDelegate.percent(from: "0.1%")), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(AppDelegate.percent(from: "54.5")), 54.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(AppDelegate.percent(from: " 54.5 % ")), 54.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(AppDelegate.percent(from: "99.99%")), 99.99, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(AppDelegate.percent(from: "0.001")), 0.001, accuracy: 0.0001)
    }

    func testPercentParsingLeadingPlusSign() {
        XCTAssertEqual(AppDelegate.percent(from: "+50"), 50.0)
        XCTAssertEqual(AppDelegate.percent(from: "+50%"), 50.0)
        XCTAssertEqual(AppDelegate.percent(from: " +100 % "), 100.0)
    }

    // MARK: - Boundary Condition Tests

    func testPercentBoundaryAtUpperLimit() {
        XCTAssertEqual(AppDelegate.percent(from: "100"), 100.0)
        XCTAssertEqual(AppDelegate.percent(from: "100.0"), 100.0)
        XCTAssertEqual(AppDelegate.percent(from: "100%"), 100.0)

        // Slightly above upper limit
        XCTAssertNil(AppDelegate.percent(from: "100.0001"))
        XCTAssertNil(AppDelegate.percent(from: "100.0001%"))
        XCTAssertNil(AppDelegate.percent(from: "100.1"))
        XCTAssertNil(AppDelegate.percent(from: "101"))
        XCTAssertNil(AppDelegate.percent(from: "101%"))
        XCTAssertNil(AppDelegate.percent(from: "200"))
        XCTAssertNil(AppDelegate.percent(from: "5000%"))
    }

    func testPercentBoundaryAtLowerLimit() throws {
        // Zero is strictly non-positive (guard v > 0)
        XCTAssertNil(AppDelegate.percent(from: "0"))
        XCTAssertNil(AppDelegate.percent(from: "0%"))
        XCTAssertNil(AppDelegate.percent(from: " 0 % "))
        XCTAssertNil(AppDelegate.percent(from: "0.0"))
        XCTAssertNil(AppDelegate.percent(from: "0.0%"))
        XCTAssertNil(AppDelegate.percent(from: "-0.0"))

        // Slightly above zero
        XCTAssertEqual(try XCTUnwrap(AppDelegate.percent(from: "0.0001")), 0.0001, accuracy: 0.00001)
    }

    func testPercentNegativeNumbers() {
        XCTAssertNil(AppDelegate.percent(from: "-1"))
        XCTAssertNil(AppDelegate.percent(from: "-1%"))
        XCTAssertNil(AppDelegate.percent(from: "-0.1"))
        XCTAssertNil(AppDelegate.percent(from: "-50"))
        XCTAssertNil(AppDelegate.percent(from: "-100"))
    }

    // MARK: - Invalid Input Tests

    func testPercentEmptyOrWhitespaceStrings() {
        XCTAssertNil(AppDelegate.percent(from: ""))
        XCTAssertNil(AppDelegate.percent(from: " "))
        XCTAssertNil(AppDelegate.percent(from: "    \t\n  "))
    }

    func testPercentOnlyPercentSymbols() {
        XCTAssertNil(AppDelegate.percent(from: "%"))
        XCTAssertNil(AppDelegate.percent(from: "%%"))
        XCTAssertNil(AppDelegate.percent(from: " % % "))
    }

    func testPercentNonNumericCharacters() {
        XCTAssertNil(AppDelegate.percent(from: "abc"))
        XCTAssertNil(AppDelegate.percent(from: "abc%"))
        XCTAssertNil(AppDelegate.percent(from: "%abc"))
        XCTAssertNil(AppDelegate.percent(from: "54pct"))
        XCTAssertNil(AppDelegate.percent(from: "54 54"))
        XCTAssertNil(AppDelegate.percent(from: "hello world"))
        XCTAssertNil(AppDelegate.percent(from: "$54"))
    }

    func testPercentSpecialFloatStrings() {
        XCTAssertNil(AppDelegate.percent(from: "NaN"))
        XCTAssertNil(AppDelegate.percent(from: "nan"))
        XCTAssertNil(AppDelegate.percent(from: "Infinity"))
        XCTAssertNil(AppDelegate.percent(from: "+Infinity"))
        XCTAssertNil(AppDelegate.percent(from: "-Infinity"))
        XCTAssertNil(AppDelegate.percent(from: "inf"))
    }
}
