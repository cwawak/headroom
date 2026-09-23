import XCTest
@testable import Headroom

final class ProbeTests: XCTestCase {

    // MARK: - Authoritative Reading Tests

    func testFormattedReadingAuthoritativeWithoutResetShortWindow() {
        let reading = Reading.authoritative(percent: 85.0, resetsAt: nil)
        let formatted = Probe.formattedReading(for: .short, reading: reading)
        XCTAssertEqual(formatted, "  5H   85%  exact")
    }

    func testFormattedReadingAuthoritativeWithoutResetLongWindow() {
        let reading = Reading.authoritative(percent: 85.0, resetsAt: nil)
        let formatted = Probe.formattedReading(for: .long, reading: reading)
        XCTAssertEqual(formatted, "  WK   85%  exact")
    }

    func testFormattedReadingAuthoritativeWithResetDate() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let reset = now.addingTimeInterval(3600) // 1 hour later
        let reading = Reading.authoritative(percent: 50.0, resetsAt: reset)

        let formatted = Probe.formattedReading(for: .short, reading: reading, relativeTo: now)
        let expectedResetString = RelativeDateTimeFormatter().localizedString(for: reset, relativeTo: now)

        XCTAssertTrue(formatted.hasPrefix("  5H   50%  exact  resets "))
        XCTAssertTrue(formatted.contains(expectedResetString))
    }

    func testFormattedReadingAuthoritativePercentageBoundariesAndRounding() {
        // Zero percent
        let zeroReading = Reading.authoritative(percent: 0.0, resetsAt: nil)
        XCTAssertEqual(Probe.formattedReading(for: .short, reading: zeroReading), "  5H    0%  exact")

        // Single digit percent
        let singleDigitReading = Reading.authoritative(percent: 5.0, resetsAt: nil)
        XCTAssertEqual(Probe.formattedReading(for: .short, reading: singleDigitReading), "  5H    5%  exact")

        // 100 percent
        let fullReading = Reading.authoritative(percent: 100.0, resetsAt: nil)
        XCTAssertEqual(Probe.formattedReading(for: .short, reading: fullReading), "  5H  100%  exact")

        // Over 100 percent (overflow / heavy usage)
        let overReading = Reading.authoritative(percent: 125.0, resetsAt: nil)
        XCTAssertEqual(Probe.formattedReading(for: .short, reading: overReading), "  5H  125%  exact")

        // Rounding down (42.4% -> 42%)
        let roundDownReading = Reading.authoritative(percent: 42.4, resetsAt: nil)
        XCTAssertEqual(Probe.formattedReading(for: .short, reading: roundDownReading), "  5H   42%  exact")

        // Rounding up (42.6% -> 43%)
        let roundUpReading = Reading.authoritative(percent: 42.6, resetsAt: nil)
        XCTAssertEqual(Probe.formattedReading(for: .short, reading: roundUpReading), "  5H   43%  exact")
    }

    // MARK: - Estimated Reading Tests

    func testFormattedReadingEstimatedWithoutResetShortWindow() {
        let reading = Reading.estimated(percent: 42.0, confidence: 0.95, resetsAt: nil)
        let formatted = Probe.formattedReading(for: .short, reading: reading)
        XCTAssertEqual(formatted, "  5H   42%  est (conf 0.95)")
    }

    func testFormattedReadingEstimatedWithoutResetLongWindow() {
        let reading = Reading.estimated(percent: 42.0, confidence: 0.95, resetsAt: nil)
        let formatted = Probe.formattedReading(for: .long, reading: reading)
        XCTAssertEqual(formatted, "  WK   42%  est (conf 0.95)")
    }

    func testFormattedReadingEstimatedConfidenceFormatting() {
        // Confidence 1.00
        let conf1 = Reading.estimated(percent: 10.0, confidence: 1.0, resetsAt: nil)
        XCTAssertEqual(Probe.formattedReading(for: .short, reading: conf1), "  5H   10%  est (conf 1.00)")

        // Confidence 0.50
        let confHalf = Reading.estimated(percent: 10.0, confidence: 0.5, resetsAt: nil)
        XCTAssertEqual(Probe.formattedReading(for: .short, reading: confHalf), "  5H   10%  est (conf 0.50)")

        // Confidence 0.00
        let confZero = Reading.estimated(percent: 10.0, confidence: 0.0, resetsAt: nil)
        XCTAssertEqual(Probe.formattedReading(for: .short, reading: confZero), "  5H   10%  est (conf 0.00)")
    }

    func testFormattedReadingEstimatedIgnoresResetDate() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let reset = now.addingTimeInterval(3600)
        let reading = Reading.estimated(percent: 50.0, confidence: 0.8, resetsAt: reset)

        let formatted = Probe.formattedReading(for: .short, reading: reading, relativeTo: now)
        XCTAssertEqual(formatted, "  5H   50%  est (conf 0.80)")
        XCTAssertFalse(formatted.contains("resets"))
    }

    // MARK: - Unavailable Reading Tests

    func testFormattedReadingUnavailableShortWindow() {
        let reading = Reading.unavailable(reason: "no logs found")
        let formatted = Probe.formattedReading(for: .short, reading: reading)
        XCTAssertEqual(formatted, "  5H    —   no logs found")
    }

    func testFormattedReadingUnavailableLongWindow() {
        let reading = Reading.unavailable(reason: "rate limit exceeded")
        let formatted = Probe.formattedReading(for: .long, reading: reading)
        XCTAssertEqual(formatted, "  WK    —   rate limit exceeded")
    }

    func testFormattedReadingUnavailableEmptyReason() {
        let reading = Reading.unavailable(reason: "")
        let formatted = Probe.formattedReading(for: .short, reading: reading)
        XCTAssertEqual(formatted, "  5H    —   ")
    }

    // MARK: - Print Readings Tests

    func testPrintReadingsExecutesWithoutErrorForFullSnapshot() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let snapshot = Snapshot(
            provider: .codex,
            readings: [
                .short: Reading.authoritative(percent: 30.0, resetsAt: nil),
                .long: Reading.estimated(percent: 60.0, confidence: 0.9, resetsAt: nil)
            ],
            capturedAt: now,
            sourceDate: now,
            planLabel: "Pro",
            rawWeighted: nil
        )

        // Verifying printReadings executes cleanly without trapped errors or crashes
        Probe.printReadings(for: snapshot, relativeTo: now)
    }

    func testPrintReadingsExecutesWithoutErrorForPartialSnapshot() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let snapshot = Snapshot(
            provider: .claude,
            readings: [
                .short: Reading.unavailable(reason: "No data available")
            ],
            capturedAt: now,
            sourceDate: now,
            planLabel: nil,
            rawWeighted: nil
        )

        Probe.printReadings(for: snapshot, relativeTo: now)
    }

    func testPrintReadingsExecutesWithoutErrorForEmptySnapshot() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let snapshot = Snapshot(
            provider: .gemini,
            readings: [:],
            capturedAt: now,
            sourceDate: nil,
            planLabel: nil,
            rawWeighted: nil
        )

        Probe.printReadings(for: snapshot, relativeTo: now)
    }
}
