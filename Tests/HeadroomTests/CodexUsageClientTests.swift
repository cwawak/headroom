import XCTest
@testable import Headroom

final class CodexUsageClientTests: XCTestCase {
    private let response = #"{"rateLimits":{"limitId":"premium","primary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1900000000}}},"rateLimitResetCredits":{"availableCount":4}}"#

    func testDecodesCodexBucketAndTopLevelResetCredits() throws {
        let limits = try CodexUsageClient.decode(Data(response.utf8))
        XCTAssertEqual(limits.primary?.usedPercent, 34)
        XCTAssertEqual(limits.primary?.windowMinutes, 10_080)
        XCTAssertEqual(limits.rateLimitResetCredits?.availableCount, 4)
        XCTAssertEqual(CodexProvider.readings(from: limits)[.long]?.percentRemaining, 66)
    }

    func testRejectsUnrelatedQuotaAndEmptyUsage() {
        for json in [#"{"rateLimits":{"limitId":"premium","primary":{"usedPercent":0,"windowDurationMins":10080}}}"#,
                     #"{"rateLimits":{"limitId":"codex","primary":null,"secondary":null}}"#] {
            XCTAssertThrowsError(try CodexUsageClient.decode(Data(json.utf8)))
        }
    }

    func testCachesSuccessAndBacksOffAfterFailureWithoutChangingSourceDate() throws {
        final class State: @unchecked Sendable { var calls = 0 }
        let state = State()
        let limits = try CodexUsageClient.decode(Data(response.utf8))
        let client = CodexUsageClient {
            state.calls += 1
            if state.calls > 1 { throw CodexUsageClient.ClientError.requestFailed }
            return limits
        }
        let now = Date()
        XCTAssertFalse(try XCTUnwrap(client.latest(now: now)).isCached)
        XCTAssertFalse(try XCTUnwrap(client.latest(now: now.addingTimeInterval(59))).isCached)
        XCTAssertEqual(state.calls, 1)
        let fallback = try XCTUnwrap(client.latest(now: now.addingTimeInterval(60)))
        XCTAssertTrue(fallback.isCached)
        XCTAssertEqual(fallback.date, now)
        XCTAssertTrue(try XCTUnwrap(client.latest(now: now.addingTimeInterval(61))).isCached)
        XCTAssertEqual(state.calls, 2)
    }

    func testProcessTransportOnlyRequestsUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex")
        let fixture = """
        #!/bin/sh
        IFS= read -r line
        case "$line" in *initialize*) ;; *) exit 1;; esac
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r line
        case "$line" in *initialized*) ;; *) exit 1;; esac
        IFS= read -r line
        case "$line" in *account/rateLimits/read*) ;; *) exit 1;; esac
        printf '%s\\n' '{"method":"account/rateLimits/updated","params":{}}'
        printf '%s\\n' '{"id":2,"result":\(response)}'
        """
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let limits = try CodexUsageClient.request(executable: script, timeout: 2)
        XCTAssertEqual(limits.primary?.usedPercent, 34)
    }

    func testProcessTimeoutIsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex")
        try "#!/bin/sh\nwhile IFS= read -r line; do :; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let start = Date()
        XCTAssertThrowsError(try CodexUsageClient.request(executable: script, timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testHistoricalFallbackCannotTriggerFalseResetNotification() {
        let detector = ResetDetector(center: nil)
        let now = Date()
        func snapshot(used: Double, isCached: Bool) -> Snapshot {
            Snapshot(provider: .codex,
                     readings: [.long: .authoritative(percent: used, resetsAt: now.addingTimeInterval(3600))],
                     capturedAt: now, sourceDate: now, planLabel: "prolite", rawWeighted: nil,
                     isCached: isCached)
        }
        XCTAssertTrue(detector.inspect(snapshots: [.codex: snapshot(used: 34, isCached: false)]).isEmpty)
        XCTAssertTrue(detector.inspect(snapshots: [.codex: snapshot(used: 7, isCached: true)]).isEmpty)
        XCTAssertTrue(detector.inspect(snapshots: [.codex: snapshot(used: 35, isCached: false)]).isEmpty)
    }
}
