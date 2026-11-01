import XCTest
@testable import Headroom

final class AntigravityProviderTests: XCTestCase {

    private let sampleJSON = """
    {
      "response": {
        "groups": [
          {
            "displayName": "Gemini Models",
            "description": "Models within this group: Gemini Flash, Gemini Pro",
            "buckets": [
              {
                "bucketId": "gemini-weekly",
                "displayName": "Weekly Limit Remaining",
                "window": "weekly",
                "remainingFraction": 0.85,
                "resetTime": "2026-11-08T16:00:00Z"
              },
              {
                "bucketId": "gemini-5h",
                "displayName": "Five Hour Limit Remaining",
                "window": "5h",
                "remainingFraction": 0.70,
                "resetTime": "2026-11-01T21:00:00Z"
              }
            ]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    func testParseQuotaSummaryValidData() {
        let readings = AntigravityProvider.parseQuotaSummary(data: sampleJSON)
        XCTAssertNotNil(readings)
        guard let readings else { return }

        // Short window: remaining 70% -> used 30%
        guard let short = readings[.short] else {
            XCTFail("Missing .short reading")
            return
        }
        XCTAssertEqual(short.percentUsed!, 30.0, accuracy: 0.01)
        XCTAssertEqual(short.percentRemaining!, 70.0, accuracy: 0.01)
        XCTAssertTrue(short.isExact)
        XCTAssertNotNil(short.resetsAt)

        // Long window: remaining 85% -> used 15%
        guard let long = readings[.long] else {
            XCTFail("Missing .long reading")
            return
        }
        XCTAssertEqual(long.percentUsed!, 15.0, accuracy: 0.01)
        XCTAssertEqual(long.percentRemaining!, 85.0, accuracy: 0.01)
        XCTAssertTrue(long.isExact)
        XCTAssertNotNil(long.resetsAt)
    }

    func testParseQuotaSummaryWithFractionalSeconds() {
        let json = """
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {
                    "bucketId": "gemini-5h",
                    "remainingFraction": 0.95,
                    "resetTime": "2026-11-01T21:00:00.123Z"
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let readings = AntigravityProvider.parseQuotaSummary(data: json)
        XCTAssertNotNil(readings)
        XCTAssertNotNil(readings?[.short]?.resetsAt)
    }

    func testParseQuotaSummaryEmptyOrMissingGroups() {
        let emptyJSON = "{}".data(using: .utf8)!
        XCTAssertNil(AntigravityProvider.parseQuotaSummary(data: emptyJSON))

        let noBucketsJSON = """
        {
          "response": {
            "groups": []
          }
        }
        """.data(using: .utf8)!
        XCTAssertNil(AntigravityProvider.parseQuotaSummary(data: noBucketsJSON))
    }

    func testSnapshotWithCustomProbe() throws {
        let provider = AntigravityProvider()
        let resetDate = Date(timeIntervalSince1970: 1700000000)
        let sourceDate = Date(timeIntervalSince1970: 1699999000)

        provider.customProbe = {
            ([
                .short: .authoritative(percent: 10.0, resetsAt: resetDate),
                .long: .authoritative(percent: 25.0, resetsAt: resetDate)
            ], sourceDate)
        }

        let snap = try provider.snapshot()
        XCTAssertEqual(snap.provider, .antigravity)
        XCTAssertEqual(snap.planLabel, "Antigravity")
        XCTAssertEqual(snap.sourceDate, sourceDate)
        XCTAssertEqual(snap.readings[.short]?.percentRemaining, 90.0)
        XCTAssertEqual(snap.readings[.long]?.percentRemaining, 75.0)
    }

    func testSnapshotWhenNotInstalled() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = AntigravityProvider()
        provider.customHome = tempDir

        if !provider.isInstalled() {
            let snap = try provider.snapshot()
            XCTAssertEqual(snap.readings[.short]?.percentRemaining, nil)
            if case .unavailable(let reason) = snap.readings[.short]! {
                XCTAssertEqual(reason, "not installed")
            } else {
                XCTFail("Expected .unavailable reading")
            }
        }
    }

    func testWatchRootsIncludesConversationsOrInstalledURL() {
        let provider = AntigravityProvider()
        let roots = provider.watchRoots()
        if provider.isInstalled() {
            XCTAssertFalse(roots.isEmpty)
        }
    }
}
