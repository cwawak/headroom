import XCTest
@testable import Headroom

final class CodexProviderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func rollout(_ name: String, date: Date, used: Double,
                         modified: Date = Date(), limitID: String = "codex") throws -> URL {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let event: [String: Any] = [
            "timestamp": ISO8601DateFormatter.withFractional.string(from: date),
            "payload": ["type": "token_count", "rate_limits": [
                "limit_id": limitID, "plan_type": "prolite",
                "primary": ["used_percent": used, "window_minutes": 10_080,
                            "resets_at": Date().addingTimeInterval(3600).timeIntervalSince1970]
            ]]
        ]
        var data = try JSONSerialization.data(withJSONObject: event)
        data.append(0x0A)
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified, .posixPermissions: 0o600],
                                              ofItemAtPath: file.path)
        return file
    }

    func testSelectsNewestQuotaTimestampInsteadOfNewestFileModification() throws {
        let now = Date()
        try rollout("2026/10/28/rollout-touched.jsonl", date: now.addingTimeInterval(-600), used: 0)
        try rollout("2026/11/01/rollout-current.jsonl", date: now.addingTimeInterval(-60), used: 7,
                    modified: now.addingTimeInterval(-60))
        let provider = CodexProvider()
        provider.customSessionsRoot = root

        let snapshot = try provider.snapshot()
        XCTAssertEqual(snapshot.readings[.long]?.percentRemaining, 93)
        XCTAssertEqual(snapshot.sourceDate!.timeIntervalSince1970,
                       now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(snapshot.isCached)
    }

    func testFindsResumedOldSessionBeyondCandidateAndDirectoryLimits() throws {
        let now = Date()
        for day in 2...15 {
            try rollout("2026/10/\(day)/rollout-stale.jsonl", date: now.addingTimeInterval(-600), used: 0)
        }
        try rollout("2026/09/01/rollout-resumed.jsonl", date: now.addingTimeInterval(-60), used: 37,
                    modified: now.addingTimeInterval(-60))
        let provider = CodexProvider()
        provider.customSessionsRoot = root
        XCTAssertEqual(try provider.snapshot().readings[.long]?.percentRemaining, 63)
    }

    func testStaleQuotaIsExplicitlyCached() throws {
        try rollout("2026/10/28/rollout-old.jsonl", date: Date().addingTimeInterval(-6 * 86400), used: 0)
        let provider = CodexProvider()
        provider.customSessionsRoot = root
        XCTAssertTrue(try provider.snapshot().isCached)
    }

    func testSkipsPremiumBucketEvenWhenItHasPercentages() throws {
        let now = Date()
        let file = try rollout("2026/11/01/rollout-current.jsonl", date: now.addingTimeInterval(-60), used: 7)
        let premium = try rollout("2026/11/01/rollout-premium.jsonl", date: now, used: 0, limitID: "premium")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contentsOf: premium))
        try handle.close()
        let provider = CodexProvider()
        provider.customSessionsRoot = root
        XCTAssertEqual(try provider.snapshot().readings[.long]?.percentRemaining, 93)
    }

    func testCachedTailRefreshesWhenFileChangesAndRejectsChangedPermissions() throws {
        let now = Date()
        let file = try rollout("2026/11/01/rollout-current.jsonl", date: now.addingTimeInterval(-60), used: 7)
        let provider = CodexProvider()
        provider.customSessionsRoot = root
        XCTAssertEqual(try provider.snapshot().readings[.long]?.percentRemaining, 93)
        try rollout("2026/11/01/rollout-current.jsonl", date: now, used: 20)
        XCTAssertEqual(try provider.snapshot().readings[.long]?.percentRemaining, 80)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        XCTAssertNil(try provider.snapshot().readings[.long]?.percentRemaining)
    }

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
