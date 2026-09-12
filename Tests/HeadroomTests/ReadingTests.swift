import XCTest
@testable import Headroom

final class ReadingTests: XCTestCase {

    // MARK: - percentUsed Edge Case Tests

    func testPercentUsedAuthoritative() {
        let now = Date()

        // Standard percentage
        let normal = Reading.authoritative(percent: 45.0, resetsAt: now)
        XCTAssertEqual(normal.percentUsed, 45.0)

        // Lower boundary (0.0%)
        let zero = Reading.authoritative(percent: 0.0, resetsAt: nil)
        XCTAssertEqual(zero.percentUsed, 0.0)

        // Upper boundary (100.0%)
        let full = Reading.authoritative(percent: 100.0, resetsAt: now)
        XCTAssertEqual(full.percentUsed, 100.0)

        // Edge case: Negative percentage (underflow)
        let negative = Reading.authoritative(percent: -15.5, resetsAt: nil)
        XCTAssertEqual(negative.percentUsed, -15.5)

        // Edge case: Over 100% (overflow / overconsumption)
        let overconsumed = Reading.authoritative(percent: 140.0, resetsAt: now)
        XCTAssertEqual(overconsumed.percentUsed, 140.0)
    }

    func testPercentUsedEstimated() {
        let now = Date()

        // Standard percentage with high confidence
        let highConf = Reading.estimated(percent: 62.5, confidence: 0.95, resetsAt: now)
        XCTAssertEqual(highConf.percentUsed, 62.5)

        // Zero percent with zero confidence
        let zeroConf = Reading.estimated(percent: 0.0, confidence: 0.0, resetsAt: nil)
        XCTAssertEqual(zeroConf.percentUsed, 0.0)

        // 100% full estimation
        let fullEst = Reading.estimated(percent: 100.0, confidence: 0.5, resetsAt: now)
        XCTAssertEqual(fullEst.percentUsed, 100.0)

        // Edge case: Negative percentage estimation
        let negativeEst = Reading.estimated(percent: -5.0, confidence: 0.1, resetsAt: nil)
        XCTAssertEqual(negativeEst.percentUsed, -5.0)

        // Edge case: Over 100% estimation
        let overEst = Reading.estimated(percent: 200.0, confidence: 0.8, resetsAt: now)
        XCTAssertEqual(overEst.percentUsed, 200.0)
    }

    func testPercentUsedUnavailable() {
        // Standard unavailable reason
        let unavailable = Reading.unavailable(reason: "Rate limit exceeded")
        XCTAssertNil(unavailable.percentUsed)

        // Empty reason string
        let emptyReason = Reading.unavailable(reason: "")
        XCTAssertNil(emptyReason.percentUsed)
    }

    // MARK: - percentRemaining Tests

    func testPercentRemainingEdgeCases() {
        // Standard authoritative calculation: 100 - 30 = 70
        let normal = Reading.authoritative(percent: 30.0, resetsAt: nil)
        XCTAssertEqual(normal.percentRemaining, 70.0)

        // 0% used = 100% remaining
        let zero = Reading.authoritative(percent: 0.0, resetsAt: nil)
        XCTAssertEqual(zero.percentRemaining, 100.0)

        // 100% used = 0% remaining
        let full = Reading.authoritative(percent: 100.0, resetsAt: nil)
        XCTAssertEqual(full.percentRemaining, 0.0)

        // Negative percent used (-20% used) = 120% remaining
        let negativeUsed = Reading.authoritative(percent: -20.0, resetsAt: nil)
        XCTAssertEqual(negativeUsed.percentRemaining, 120.0)

        // Over 100% used (130% used) = -30% remaining
        let overUsed = Reading.authoritative(percent: 130.0, resetsAt: nil)
        XCTAssertEqual(overUsed.percentRemaining, -30.0)

        // Estimated reading percent remaining
        let estimated = Reading.estimated(percent: 45.0, confidence: 0.8, resetsAt: nil)
        XCTAssertEqual(estimated.percentRemaining, 55.0)

        // Unavailable reading percent remaining is nil
        let unavailable = Reading.unavailable(reason: "No data")
        XCTAssertNil(unavailable.percentRemaining)
    }

    // MARK: - resetsAt & isExact Tests

    func testResetsAtAndIsExact() {
        let resetDate = Date(timeIntervalSince1970: 1700000000)

        let authWithDate = Reading.authoritative(percent: 50.0, resetsAt: resetDate)
        XCTAssertEqual(authWithDate.resetsAt, resetDate)
        XCTAssertTrue(authWithDate.isExact)

        let authNoDate = Reading.authoritative(percent: 50.0, resetsAt: nil)
        XCTAssertNil(authNoDate.resetsAt)
        XCTAssertTrue(authNoDate.isExact)

        let estWithDate = Reading.estimated(percent: 50.0, confidence: 0.9, resetsAt: resetDate)
        XCTAssertEqual(estWithDate.resetsAt, resetDate)
        XCTAssertFalse(estWithDate.isExact)

        let estNoDate = Reading.estimated(percent: 50.0, confidence: 0.9, resetsAt: nil)
        XCTAssertNil(estNoDate.resetsAt)
        XCTAssertFalse(estNoDate.isExact)

        let unavailable = Reading.unavailable(reason: "Disconnected")
        XCTAssertNil(unavailable.resetsAt)
        XCTAssertFalse(unavailable.isExact)
    }
}
