import XCTest
@testable import Headroom

final class HeadroomTests: XCTestCase {
    func testSanity() {
        XCTAssertTrue(true)
    }

    func testProbeFormattedReadingAuthoritativeWithoutReset() {
        let reading = Reading.authoritative(percent: 85.0, resetsAt: nil)
        let formatted = Probe.formattedReading(for: .short, reading: reading)
        XCTAssertEqual(formatted, "  5H   85%  exact")
    }

    func testProbeFormattedReadingAuthoritativeWithReset() {
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        let reading = Reading.authoritative(percent: 50.0, resetsAt: reset)
        let formatted = Probe.formattedReading(for: .short, reading: reading, relativeTo: now)
        XCTAssertTrue(formatted.hasPrefix("  5H   50%  exact  resets "))
    }

    func testProbeFormattedReadingEstimated() {
        let reading = Reading.estimated(percent: 42.0, confidence: 0.95, resetsAt: nil)
        let formatted = Probe.formattedReading(for: .long, reading: reading)
        XCTAssertEqual(formatted, "  WK   42%  est (conf 0.95)")
    }

    func testProbeFormattedReadingUnavailable() {
        let reading = Reading.unavailable(reason: "no logs found")
        let formatted = Probe.formattedReading(for: .short, reading: reading)
        XCTAssertEqual(formatted, "  5H    —   no logs found")
    }
}
