import XCTest
@testable import Headroom

final class CodexProviderTests: XCTestCase {
    func testWeeklyPrimaryWindowMapsToWeeklyReading() {
        let limits = RateLimits(
            limitId: "codex",
            planType: "prolite",
            primary: RateWindow(usedPercent: 34, windowMinutes: 10_080, resetsAt: nil),
            secondary: nil
        )

        let readings = CodexProvider.readings(from: limits)

        guard case .authoritative(let used, _) = readings[.long] else {
            return XCTFail("Expected the 10,080-minute record to be the weekly reading")
        }
        XCTAssertEqual(used, 34)

        guard case .unavailable = readings[.short] else {
            return XCTFail("A weekly-only record must not appear as a five-hour reading")
        }
    }

    func testShortAndWeeklyWindowsMapByDuration() {
        let limits = RateLimits(
            limitId: "codex",
            planType: "prolite",
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: 10_080, resetsAt: nil)
        )

        let readings = CodexProvider.readings(from: limits)

        guard case .authoritative(let shortUsed, _) = readings[.short] else {
            return XCTFail("Expected the 300-minute record to be the five-hour reading")
        }
        XCTAssertEqual(shortUsed, 20)

        guard case .authoritative(let weeklyUsed, _) = readings[.long] else {
            return XCTFail("Expected the 10,080-minute record to be the weekly reading")
        }
        XCTAssertEqual(weeklyUsed, 34)
    }
}
