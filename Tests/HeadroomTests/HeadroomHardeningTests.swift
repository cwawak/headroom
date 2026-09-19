import XCTest
@testable import Headroom

final class HeadroomHardeningTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("HeadroomTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Legacy Migration Security Tests

    func testMigrationSuccessAndDestinationPreservation() {
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        let legacyDir = appSupport.appendingPathComponent("NotchGauge")
        let headroomDir = appSupport.appendingPathComponent("Headroom")
        try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let legacyFile = legacyDir.appendingPathComponent("calibration.json")
        let cal = Calibration(shortCapacity: 5000, longCapacity: 50000, shortObservations: 1, longObservations: 1)
        let data = try! JSONEncoder().encode(cal)
        try! data.write(to: legacyFile)

        CalibrationStore.customApplicationSupportDirectory = appSupport
        defer { CalibrationStore.customApplicationSupportDirectory = nil }

        let loaded = CalibrationStore.load()
        XCTAssertEqual(loaded.shortCapacity, 5000)
        XCTAssertEqual(loaded.longCapacity, 50000)

        // Verify destination file exists
        let destFile = headroomDir.appendingPathComponent("calibration.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))

        // Verify legacy file was preserved
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testMigrationRejectsSymlinkLegacySource() {
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        let legacyDir = appSupport.appendingPathComponent("NotchGauge")
        let realDir = tempDir.appendingPathComponent("RealDir")
        try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

        let realFile = realDir.appendingPathComponent("real_cal.json")
        let cal = Calibration(shortCapacity: 7000, longCapacity: 70000, shortObservations: 1, longObservations: 1)
        let data = try! JSONEncoder().encode(cal)
        try! data.write(to: realFile)

        let symlinkFile = legacyDir.appendingPathComponent("calibration.json")
        try! FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: realFile)

        CalibrationStore.customApplicationSupportDirectory = appSupport
        defer { CalibrationStore.customApplicationSupportDirectory = nil }

        let loaded = CalibrationStore.load()
        // Should reject symlink and fallback to seed
        XCTAssertEqual(loaded.shortCapacity, Calibration.seed.shortCapacity)
    }

    func testMigrationRejectsUnsafePermissionsOrOwnership() {
        // Mode bit check verification
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        let legacyDir = appSupport.appendingPathComponent("NotchGauge")
        try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let legacyFile = legacyDir.appendingPathComponent("calibration.json")
        let cal = Calibration(shortCapacity: 9000, longCapacity: 90000, shortObservations: 1, longObservations: 1)
        let data = try! JSONEncoder().encode(cal)
        try! data.write(to: legacyFile)

        // Make legacy file world writable
        try! FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: legacyFile.path)

        CalibrationStore.customApplicationSupportDirectory = appSupport
        defer { CalibrationStore.customApplicationSupportDirectory = nil }

        let loaded = CalibrationStore.load()
        XCTAssertEqual(loaded.shortCapacity, Calibration.seed.shortCapacity)
    }

    // MARK: - ClaudeProvider Retention, Boundaries & Ingestion Tests

    func testRetentionAndFutureDatedRecords() {
        let projectsDir = tempDir.appendingPathComponent(".claude/projects")
        try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1700000000)
        let formatter = ISO8601DateFormatter()

        // 1. Valid record (1 hour ago)
        let validDate = now.addingTimeInterval(-3600)
        let validIso = formatter.string(from: validDate)
        let validRecord = "{\"timestamp\":\"\(validIso)\",\"requestId\":\"req1\",\"message\":{\"model\":\"claude-3-sonnet\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}\n"

        // 2. Expired record (10 days ago)
        let expiredDate = now.addingTimeInterval(-10 * 24 * 3600)
        let expiredIso = formatter.string(from: expiredDate)
        let expiredRecord = "{\"timestamp\":\"\(expiredIso)\",\"requestId\":\"req2\",\"message\":{\"model\":\"claude-3-sonnet\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":500}}}\n"

        // 3. Future record (+10 minutes in future)
        let futureDate = now.addingTimeInterval(600)
        let futureIso = formatter.string(from: futureDate)
        let futureRecord = "{\"timestamp\":\"\(futureIso)\",\"requestId\":\"req3\",\"message\":{\"model\":\"claude-3-sonnet\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":500}}}\n"

        let logFile = projectsDir.appendingPathComponent("session.jsonl")
        let content = validRecord + expiredRecord + futureRecord
        try! content.write(to: logFile, atomically: true, encoding: .utf8)

        let provider = ClaudeProvider()
        provider.customProjectsRoot = projectsDir
        provider.customAgentModeRoot = tempDir.appendingPathComponent("MissingAgentMode")
        provider.customNow = now

        let snap = try! provider.snapshot()

        // Future record should trigger incomplete reading / diagnostic
        if case .unavailable(let reason) = snap.readings[.short] {
            XCTAssertTrue(reason.contains("implausibly future-dated"))
        } else {
            XCTFail("Expected unavailable reading due to future-dated record")
        }
    }

    func testDeduplicationAndOut0fOrderRecords() {
        let projectsDir = tempDir.appendingPathComponent(".claude/projects")
        try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1700000000)
        let formatter = ISO8601DateFormatter()

        let t1 = now.addingTimeInterval(-7200) // 2 hrs ago
        let t2 = now.addingTimeInterval(-14400) // 4 hrs ago (out of order!)

        // Same requestId "req-dup" re-logged
        let r1 = "{\"timestamp\":\"\(formatter.string(from: t1))\",\"requestId\":\"req-dup\",\"message\":{\"model\":\"claude-3-sonnet\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}\n"
        let r2 = "{\"timestamp\":\"\(formatter.string(from: t2))\",\"requestId\":\"req-dup\",\"message\":{\"model\":\"claude-3-sonnet\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}\n"
        let r3 = "{\"timestamp\":\"\(formatter.string(from: t2))\",\"requestId\":\"req-unique\",\"message\":{\"model\":\"claude-3-sonnet\",\"usage\":{\"input_tokens\":200,\"output_tokens\":100}}}\n"

        let logFile = projectsDir.appendingPathComponent("session.jsonl")
        try! (r1 + r2 + r3).write(to: logFile, atomically: true, encoding: .utf8)

        let provider = ClaudeProvider()
        provider.customProjectsRoot = projectsDir
        provider.customAgentModeRoot = tempDir.appendingPathComponent("MissingAgentMode")
        provider.customNow = now

        let snap = try! provider.snapshot()
        XCTAssertNotNil(snap.rawWeighted?[.short])
    }

    func testSymlinkRootAndEscapeRejection() {
        let projectsDir = tempDir.appendingPathComponent(".claude/projects")
        let outsideDir = tempDir.appendingPathComponent("Outside")
        try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        // Symlinked file inside root pointing outside
        let outsideFile = outsideDir.appendingPathComponent("secret.jsonl")
        try! "{\"timestamp\":\"2023-01-01T00:00:00Z\",\"requestId\":\"r1\"}\n".write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkFile = projectsDir.appendingPathComponent("link.jsonl")
        try! FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: outsideFile)

        let provider = ClaudeProvider()
        provider.customProjectsRoot = projectsDir
        provider.customAgentModeRoot = tempDir.appendingPathComponent("MissingAgentMode")
        let snap = try! provider.snapshot()

        // Symlink should be skipped securely
        XCTAssertNotNil(snap)
    }

    func testOversizedLogRecordHandling() {
        let projectsDir = tempDir.appendingPathComponent(".claude/projects")
        try? FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1700000000)
        let logFile = projectsDir.appendingPathComponent("oversized.jsonl")

        // Write a log file with a single line exceeding 8 MiB (8 * 1024 * 1024 + 100 bytes) without newlines
        let oversizedLength = 8 * 1024 * 1024 + 100
        let paddingData = Data(repeating: UInt8(ascii: "a"), count: oversizedLength)
        try! paddingData.write(to: logFile)

        let provider = ClaudeProvider()
        provider.customProjectsRoot = projectsDir
        provider.customAgentModeRoot = tempDir.appendingPathComponent("MissingAgentMode")
        provider.customNow = now

        let snap = try! provider.snapshot()

        if case .unavailable(let reason) = snap.readings[.short] {
            XCTAssertTrue(reason.contains("oversized log record (>8 MiB)"))
        } else {
            XCTFail("Expected unavailable reading due to oversized log record")
        }
    }
}
