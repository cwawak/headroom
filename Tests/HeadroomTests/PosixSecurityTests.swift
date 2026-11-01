import XCTest
@testable import Headroom

final class PosixSecurityTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PosixSecurityTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDown() {
        if let tempDir = tempDir {
            // Restore write permissions before deletion in case tests altered directory permissions
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Constants Tests

    func testMaxCalibrationFileSizeConstant() {
        XCTAssertEqual(PosixSecurity.maxCalibrationFileSize, 64 * 1024)
        XCTAssertEqual(PosixSecurity.maxCalibrationFileSize, 65536)
    }

    // MARK: - verifyACLSafety Tests

    func testVerifyACLSafetyReturnsTrueForSafePath() throws {
        let testFile = tempDir.appendingPathComponent("safe_file.txt")
        try "test data".write(to: testFile, atomically: true, encoding: .utf8)

        XCTAssertTrue(PosixSecurity.verifyACLSafety(path: testFile.path))
    }

    func testVerifyACLSafetyReturnsTrueForNonExistentPath() {
        let missingPath = tempDir.appendingPathComponent("missing_file.txt").path
        XCTAssertTrue(PosixSecurity.verifyACLSafety(path: missingPath))
    }

    // MARK: - verifyDirectoryChain Tests

    func testVerifyDirectoryChainSuccessForStandardSubdirectory() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let subDir = baseDir.appendingPathComponent("SubDir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = subDir.appendingPathComponent("target.json")

        XCTAssertTrue(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: targetFile.path))
    }

    func testVerifyDirectoryChainSuccessForDeeplyNestedDirectories() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let deepDir = baseDir.appendingPathComponent("Level1/Level2/Level3")
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        let targetFile = deepDir.appendingPathComponent("target.json")

        XCTAssertTrue(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: targetFile.path))
    }

    func testVerifyDirectoryChainSuccessWhenTargetIsDirectChildOfBase() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = baseDir.appendingPathComponent("direct_child.json")

        XCTAssertTrue(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: targetFile.path))
    }

    func testVerifyDirectoryChainRejectsTargetOutsideBase() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let outsideDir = tempDir.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = outsideDir.appendingPathComponent("target.json")

        XCTAssertFalse(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: targetFile.path))
    }

    func testVerifyDirectoryChainRejectsPathTraversalOutsideBase() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let traversalPath = baseDir.path + "/../escaped.json"

        XCTAssertFalse(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: traversalPath))
    }

    func testVerifyDirectoryChainRejectsPrefixCollision() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let siblingDir = tempDir.appendingPathComponent("BaseSibling")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = siblingDir.appendingPathComponent("target.json")

        XCTAssertFalse(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: targetFile.path))
    }

    func testVerifyDirectoryChainRejectsNonExistentDirectory() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let nonExistentDir = baseDir.appendingPathComponent("DoesNotExist")
        let targetFile = nonExistentDir.appendingPathComponent("target.json")

        XCTAssertFalse(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: targetFile.path))
    }

    func testVerifyDirectoryChainRejectsFileInDirectoryChain() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let regularFile = baseDir.appendingPathComponent("NotADir")
        try "contents".write(to: regularFile, atomically: true, encoding: .utf8)

        // Attempting to treat regularFile as a directory in path
        let targetFile = regularFile.appendingPathComponent("target.json")

        XCTAssertFalse(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: targetFile.path))
    }

    func testVerifyDirectoryChainRejectsSymlinkInDirectoryChain() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let realDir = tempDir.appendingPathComponent("RealDir")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let symlinkDir = baseDir.appendingPathComponent("LinkedDir")
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: realDir)

        let targetFile = symlinkDir.appendingPathComponent("target.json")

        XCTAssertFalse(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: targetFile.path))
    }

    func testVerifyDirectoryChainRejectsGroupWritableDirectory() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let subDir = baseDir.appendingPathComponent("GroupWritable")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o775])

        let targetFile = subDir.appendingPathComponent("target.json")

        XCTAssertFalse(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: targetFile.path))
    }

    func testVerifyDirectoryChainRejectsWorldWritableDirectory() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let subDir = baseDir.appendingPathComponent("WorldWritable")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])

        let targetFile = subDir.appendingPathComponent("target.json")

        XCTAssertFalse(PosixSecurity.verifyDirectoryChain(basePath: baseDir.path, targetPath: targetFile.path))
    }

    // MARK: - readSecureFile Tests

    func testReadSecureFileSuccess() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let subDir = baseDir.appendingPathComponent("Headroom")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = subDir.appendingPathComponent("calibration.json")
        let expectedData = Data("{\"shortCapacity\": 22000000}".utf8)
        try expectedData.write(to: targetFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetFile.path)

        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: targetFile.path, maxSize: 4096)
        XCTAssertEqual(readData, expectedData)
    }

    func testReadSecureFileEmptyFile() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = baseDir.appendingPathComponent("empty.json")
        let emptyData = Data()
        try emptyData.write(to: targetFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetFile.path)

        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: targetFile.path, maxSize: 1024)
        XCTAssertEqual(readData, emptyData)
    }

    func testReadSecureFileExactMaxSize() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = baseDir.appendingPathComponent("exact_size.bin")
        let payload = Data(repeating: 0x42, count: 512)
        try payload.write(to: targetFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetFile.path)

        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: targetFile.path, maxSize: 512)
        XCTAssertEqual(readData, payload)
    }

    func testReadSecureFileExceedingMaxSizeReturnsNil() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = baseDir.appendingPathComponent("too_large.bin")
        let payload = Data(repeating: 0x41, count: 1000)
        try payload.write(to: targetFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetFile.path)

        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: targetFile.path, maxSize: 500)
        XCTAssertNil(readData)
    }

    func testReadSecureFileRejectsSymlinkedTargetFile() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let outsideDir = tempDir.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let realFile = outsideDir.appendingPathComponent("secret.json")
        try "sensitive content".write(to: realFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: realFile.path)

        let symlinkFile = baseDir.appendingPathComponent("calibration.json")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: realFile)

        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: symlinkFile.path, maxSize: 4096)
        XCTAssertNil(readData)
    }

    func testReadSecureFileRejectsDirectoryTarget() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let subDir = baseDir.appendingPathComponent("SubDir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Passing a directory path as the targetPath to readSecureFile
        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: subDir.path, maxSize: 4096)
        XCTAssertNil(readData)
    }

    func testReadSecureFileRejectsGroupWritableFile() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = baseDir.appendingPathComponent("insecure_group.json")
        try "data".write(to: targetFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: targetFile.path)

        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: targetFile.path, maxSize: 4096)
        XCTAssertNil(readData)
    }

    func testReadSecureFileRejectsWorldWritableFile() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = baseDir.appendingPathComponent("insecure_world.json")
        try "data".write(to: targetFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: targetFile.path)

        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: targetFile.path, maxSize: 4096)
        XCTAssertNil(readData)
    }

    func testReadSecureFileRejectsNonExistentFile() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let nonExistentFile = baseDir.appendingPathComponent("missing.json")

        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: nonExistentFile.path, maxSize: 4096)
        XCTAssertNil(readData)
    }

    func testReadSecureFileRejectsTargetWithInsecureParentDirectory() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let insecureDir = baseDir.appendingPathComponent("InsecureDir")
        try FileManager.default.createDirectory(at: insecureDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])

        let targetFile = insecureDir.appendingPathComponent("calibration.json")
        try "{}".write(to: targetFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetFile.path)

        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: targetFile.path, maxSize: 4096)
        XCTAssertNil(readData)
    }

    func testReadSecureFileRejectsTargetOutsideBaseDirectory() throws {
        let baseDir = tempDir.appendingPathComponent("Base")
        let outsideDir = tempDir.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let targetFile = outsideDir.appendingPathComponent("calibration.json")
        try "{}".write(to: targetFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetFile.path)

        let readData = PosixSecurity.readSecureFile(basePath: baseDir.path, targetPath: targetFile.path, maxSize: 4096)
        XCTAssertNil(readData)
    }
}
