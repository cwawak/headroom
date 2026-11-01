import XCTest
@testable import Headroom

final class PreferencesAndResetTests: XCTestCase {

    func testPreferencesStoreProviderVisibility() {
        let suiteName = "testPreferencesStoreProviderVisibility_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = PreferencesStore(defaults: defaults)

        XCTAssertFalse(prefs.isProviderHidden(.codex))
        XCTAssertFalse(prefs.isProviderHidden(.claude))
        XCTAssertFalse(prefs.isProviderHidden(.antigravity))

        prefs.setProviderHidden(.codex, hidden: true)
        XCTAssertTrue(prefs.isProviderHidden(.codex))
        XCTAssertFalse(prefs.isProviderHidden(.claude))

        prefs.setProviderHidden(.codex, hidden: false)
        XCTAssertFalse(prefs.isProviderHidden(.codex))
    }

    func testPreferencesStoreShortLimitVisibility() {
        let suiteName = "testPreferencesStoreShortLimitVisibility_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = PreferencesStore(defaults: defaults)

        XCTAssertFalse(prefs.isShortLimitHidden(for: .codex))
        XCTAssertFalse(prefs.isShortLimitHidden(for: .claude))

        prefs.setShortLimitHidden(for: .codex, hidden: true)
        XCTAssertTrue(prefs.isShortLimitHidden(for: .codex))
        XCTAssertFalse(prefs.isShortLimitHidden(for: .claude))

        prefs.setShortLimitHidden(for: .codex, hidden: false)
        XCTAssertFalse(prefs.isShortLimitHidden(for: .codex))
    }

    func testCodexBankedResetDecoding() {
        let limits = RateLimits(
            limitId: "codex",
            planType: "pro",
            primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: 10_080, resetsAt: nil),
            bankedResets: 2,
            rateLimitResetCredits: nil
        )

        XCTAssertEqual(limits.bankedResets, 2)
    }

    func testResetDetectorIdentifiesAbnormalFreeReset() {
        let detector = ResetDetector()
        let now = Date(timeIntervalSince1970: 1700000000)
        let futureReset = now.addingTimeInterval(7200)

        let snap1 = [
            ProviderID.codex: Snapshot(
                provider: .codex,
                readings: [.short: .authoritative(percent: 80.0, resetsAt: futureReset)],
                capturedAt: now,
                sourceDate: now,
                planLabel: "pro",
                rawWeighted: nil
            )
        ]

        let initial = detector.inspect(snapshots: snap1, now: now)
        XCTAssertTrue(initial.isEmpty)

        // Mid-window reset to 0% before reset time
        let snap2 = [
            ProviderID.codex: Snapshot(
                provider: .codex,
                readings: [.short: .authoritative(percent: 0.0, resetsAt: futureReset)],
                capturedAt: now.addingTimeInterval(300),
                sourceDate: now.addingTimeInterval(300),
                planLabel: "pro",
                rawWeighted: nil
            )
        ]

        let resets = detector.inspect(snapshots: snap2, now: now.addingTimeInterval(300))
        XCTAssertEqual(resets.count, 1)
        if case .abnormalFreeReset(let provider, let window, let drop) = resets[0] {
            XCTAssertEqual(provider, .codex)
            XCTAssertEqual(window, .short)
            XCTAssertEqual(drop, 80.0)
        } else {
            XCTFail("Expected abnormalFreeReset")
        }
    }
}
