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
        var notifiedResets: [ResetDetector.ResetType] = []
        let detector = ResetDetector(center: nil, onNotification: { reset in
            notifiedResets.append(reset)
        })
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
        XCTAssertTrue(notifiedResets.isEmpty)

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
        XCTAssertEqual(notifiedResets.count, 1)
        if case .abnormalFreeReset(let provider, let window, let drop) = resets[0] {
            XCTAssertEqual(provider, .codex)
            XCTAssertEqual(window, .short)
            XCTAssertEqual(drop, 80.0)
        } else {
            XCTFail("Expected abnormalFreeReset")
        }
    }

    func testClaudeCalibrationDoesNotTriggerFreeReset() {
        var notifiedResets: [ResetDetector.ResetType] = []
        let detector = ResetDetector(center: nil, onNotification: { reset in
            notifiedResets.append(reset)
        })
        let now = Date(timeIntervalSince1970: 1700000000)
        let futureReset = now.addingTimeInterval(7200)

        // Claude reading is estimated, not authoritative
        let snap1 = [
            ProviderID.claude: Snapshot(
                provider: .claude,
                readings: [.short: .estimated(percent: 80.0, confidence: 0.8, resetsAt: futureReset)],
                capturedAt: now,
                sourceDate: now,
                planLabel: "calibrated",
                rawWeighted: nil
            )
        ]
        _ = detector.inspect(snapshots: snap1, now: now)

        // Recalibration drops from 80% to 40% before reset time
        let snap2 = [
            ProviderID.claude: Snapshot(
                provider: .claude,
                readings: [.short: .estimated(percent: 40.0, confidence: 0.9, resetsAt: futureReset)],
                capturedAt: now.addingTimeInterval(300),
                sourceDate: now.addingTimeInterval(300),
                planLabel: "calibrated",
                rawWeighted: nil
            )
        ]

        let resets = detector.inspect(snapshots: snap2, now: now.addingTimeInterval(300))
        XCTAssertTrue(resets.isEmpty, "Estimated readings must not trigger free quota reset alerts")
        XCTAssertTrue(notifiedResets.isEmpty)
    }

    func testScheduledResetDetectedEvenIfUsageIncreases() {
        var notifiedResets: [ResetDetector.ResetType] = []
        let detector = ResetDetector(center: nil, onNotification: { reset in
            notifiedResets.append(reset)
        })
        let now = Date(timeIntervalSince1970: 1700000000)
        let firstReset = now.addingTimeInterval(3600)
        let secondReset = firstReset.addingTimeInterval(18000)

        let snap1 = [
            ProviderID.codex: Snapshot(
                provider: .codex,
                readings: [.short: .authoritative(percent: 10.0, resetsAt: firstReset)],
                capturedAt: now,
                sourceDate: now,
                planLabel: "pro",
                rawWeighted: nil
            )
        ]
        _ = detector.inspect(snapshots: snap1, now: now)

        // After window rollover, reset timestamp moves forward to secondReset and usage started at 15% (higher than 10%)
        let inspectionTime = firstReset.addingTimeInterval(10) // After firstReset passed
        let snap2 = [
            ProviderID.codex: Snapshot(
                provider: .codex,
                readings: [.short: .authoritative(percent: 15.0, resetsAt: secondReset)],
                capturedAt: inspectionTime,
                sourceDate: inspectionTime,
                planLabel: "pro",
                rawWeighted: nil
            )
        ]

        let resets = detector.inspect(snapshots: snap2, now: inspectionTime)
        XCTAssertEqual(resets.count, 1)
        if case .normal(let provider, let window) = resets[0] {
            XCTAssertEqual(provider, .codex)
            XCTAssertEqual(window, .short)
        } else {
            XCTFail("Expected normal reset on timestamp advancement")
        }
    }

    func testDeadlineChangeBeforeExpiryDoesNotTriggerResetNotification() {
        var notifiedResets: [ResetDetector.ResetType] = []
        let detector = ResetDetector(center: nil, onNotification: { reset in
            notifiedResets.append(reset)
        })
        let now = Date(timeIntervalSince1970: 1700000000)
        let originalDeadline = now.addingTimeInterval(7200) // 2 hours in the future
        let newLaterDeadline = now.addingTimeInterval(14400) // 4 hours in the future

        let snap1 = [
            ProviderID.codex: Snapshot(
                provider: .codex,
                readings: [.short: .authoritative(percent: 25.0, resetsAt: originalDeadline)],
                capturedAt: now,
                sourceDate: now,
                planLabel: "pro",
                rawWeighted: nil
            )
        ]
        _ = detector.inspect(snapshots: snap1, now: now)

        // Deadline moved to later time while originalDeadline is still in the future, usage steady or slightly higher
        let intermediateNow = now.addingTimeInterval(600) // 10 minutes later (still way before 2 hours)
        let snap2 = [
            ProviderID.codex: Snapshot(
                provider: .codex,
                readings: [.short: .authoritative(percent: 28.0, resetsAt: newLaterDeadline)],
                capturedAt: intermediateNow,
                sourceDate: intermediateNow,
                planLabel: "pro",
                rawWeighted: nil
            )
        ]

        let resets = detector.inspect(snapshots: snap2, now: intermediateNow)
        XCTAssertTrue(resets.isEmpty, "A later reset deadline before the previous deadline expired must not trigger a reset notification")
        XCTAssertTrue(notifiedResets.isEmpty)
    }
}
