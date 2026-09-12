import Foundation

/// What one full rate-limit window costs in weighted tokens.
///
/// Anthropic doesn't publish this and Claude Code doesn't write it down, so we
/// learn it: when a `quotaLimits` rejection appears, the weighted consumption
/// over the preceding window *is* 100% of that window, observed empirically.
/// Until that happens we run on a seed constant and say so.
struct Calibration: Codable, Sendable {
    var shortCapacity: Double
    var longCapacity: Double
    /// Number of real rejection events folded in. 0 == still on the seed.
    var shortObservations: Int
    var longObservations: Int

    /// Claude's weekly limit resets on a fixed weekday and hour (the usage page
    /// says e.g. "Resets Fri 6:00 AM"), not on a rolling seven days. 1 = Sunday.
    var weeklyResetWeekday: Int = 6      // Friday
    var weeklyResetHour: Int = 6

    /// Epoch seconds of the newest rejection already folded in. Without this the
    /// same historical rejection is re-learned on every launch, dragging the
    /// capacity toward that one window a little further each time.
    var lastRejectionFolded: Double = 0

    /// Epoch seconds of the newest `utilization` observation already folded in.
    /// Same reason as above: without it, every launch re-learns the same points.
    var lastUtilizationFolded: Double = 0

    /// Hand-written so that adding a field never invalidates a saved file.
    ///
    /// Swift's synthesized `Codable` throws when a key is missing rather than
    /// falling back to the property's default, so simply adding
    /// `weeklyResetWeekday` silently reset every existing user to the seed and
    /// threw away their calibration. New fields must always be optional on read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shortCapacity = try c.decode(Double.self, forKey: .shortCapacity)
        longCapacity = try c.decode(Double.self, forKey: .longCapacity)
        shortObservations = try c.decodeIfPresent(Int.self, forKey: .shortObservations) ?? 0
        longObservations = try c.decodeIfPresent(Int.self, forKey: .longObservations) ?? 0
        weeklyResetWeekday = try c.decodeIfPresent(Int.self, forKey: .weeklyResetWeekday) ?? 6
        weeklyResetHour = try c.decodeIfPresent(Int.self, forKey: .weeklyResetHour) ?? 6
        lastRejectionFolded = try c.decodeIfPresent(Double.self, forKey: .lastRejectionFolded) ?? 0
        lastUtilizationFolded = try c.decodeIfPresent(Double.self, forKey: .lastUtilizationFolded) ?? 0
    }

    init(shortCapacity: Double, longCapacity: Double,
         shortObservations: Int, longObservations: Int,
         weeklyResetWeekday: Int = 6, weeklyResetHour: Int = 6,
         lastRejectionFolded: Double = 0, lastUtilizationFolded: Double = 0) {
        self.shortCapacity = shortCapacity
        self.longCapacity = longCapacity
        self.shortObservations = shortObservations
        self.longObservations = longObservations
        self.weeklyResetWeekday = weeklyResetWeekday
        self.weeklyResetHour = weeklyResetHour
        self.lastRejectionFolded = lastRejectionFolded
        self.lastUtilizationFolded = lastUtilizationFolded
    }

    /// Deliberately a guess, and labelled as one everywhere it surfaces.
    /// Order of magnitude only — the first real rejection replaces it.
    static let seed = Calibration(shortCapacity: 22_000_000,
                                  longCapacity: 140_000_000,
                                  shortObservations: 0,
                                  longObservations: 0,
                                  weeklyResetWeekday: 6,
                                  weeklyResetHour: 6)

    func capacity(for window: QuotaWindow) -> Double {
        window == .short ? shortCapacity : longCapacity
    }

    func observations(for window: QuotaWindow) -> Int {
        window == .short ? shortObservations : longObservations
    }

    /// Confidence rises with evidence. Drives the dashed-vs-solid meniscus.
    func confidence(for window: QuotaWindow) -> Double {
        switch observations(for: window) {
        case 0:     return 0.25          // seed only
        case 1:     return 0.6
        case 2:     return 0.75
        default:    return 0.9
        }
    }

    /// Calibrate against a figure the user read off Claude's own usage page.
    ///
    /// This beats waiting for a rate-limit rejection in every way: it needs no
    /// outage to happen, it works on the first run, and the user is reporting the
    /// same number the vendor is enforcing. `observedUsedPercent` is what their
    /// settings screen says; `weightedSum` is what we measured over the same
    /// window, so capacity falls straight out.
    mutating func calibrate(observedUsedPercent: Double, weightedSum: Double,
                            for window: QuotaWindow) {
        guard observedUsedPercent > 0, weightedSum > 0 else { return }
        let capacity = weightedSum / (observedUsedPercent / 100)
        switch window {
        case .short: shortCapacity = capacity; shortObservations = max(shortObservations, 2)
        case .long:  longCapacity = capacity;  longObservations = max(longObservations, 2)
        }
    }

    /// EWMA so one weird window can't throw the estimate off permanently.
    mutating func fold(_ observed: Double, into window: QuotaWindow) {
        guard observed > 0 else { return }
        switch window {
        case .short:
            shortCapacity = shortObservations == 0
                ? observed
                : shortCapacity * 0.7 + observed * 0.3
            shortObservations += 1
        case .long:
            longCapacity = longObservations == 0
                ? observed
                : longCapacity * 0.7 + observed * 0.3
            longObservations += 1
        }
    }
}

/// Helper functions for safe POSIX file opening and directory checking.
enum PosixSecurity {
    /// Maximum allowed file size for calibration store reads (64 KiB).
    static let maxCalibrationFileSize: Int = 64 * 1024

    /// Verifies ACL safety when macOS extended ACLs are attached to a path.
    ///
    /// Darwin exposes `acl_get_perm_np` rather than the POSIX `acl_get_perm`.
    /// Reject any allow entry containing a permission that can mutate the path.
    /// This is intentionally conservative: an owner-specific allow entry is also
    /// rejected because the qualifier is a UUID and cannot safely be treated as
    /// the file owner without another identity lookup.
    static func verifyACLSafety(path: String) -> Bool {
        #if os(macOS)
        let acl = acl_get_file(path, ACL_TYPE_EXTENDED)
        if let acl = acl {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t? = nil
            var result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
            while result == 0, let currentEntry = entry {
                var permset: acl_permset_t? = nil
                if acl_get_permset(currentEntry, &permset) == 0, let permset = permset {
                    var tagType: acl_tag_t = ACL_UNDEFINED_TAG
                    let isAllowEntry = acl_get_tag_type(currentEntry, &tagType) == 0
                        && tagType == ACL_EXTENDED_ALLOW
                    let mutationPermissions: [acl_perm_t] = [
                        ACL_WRITE_DATA,
                        ACL_APPEND_DATA,
                        ACL_DELETE,
                        ACL_DELETE_CHILD,
                        ACL_WRITE_ATTRIBUTES,
                        ACL_WRITE_EXTATTRIBUTES,
                        ACL_WRITE_SECURITY,
                        ACL_CHANGE_OWNER
                    ]
                    if isAllowEntry && mutationPermissions.contains(where: {
                        acl_get_perm_np(permset, $0) == 1
                    }) {
                        return false
                    }
                }
                result = acl_get_entry(acl, ACL_NEXT_ENTRY.rawValue, &entry)
            }
        }
        #endif
        return true
    }

    /// Verifies that all path components under `basePath` leading to `targetPath`
    /// are secure directories (owned by `geteuid()`, no group/other write permissions `022 == 0`,
    /// not symbolic links, and no insecure ACLs).
    static func verifyDirectoryChain(basePath: String, targetPath: String) -> Bool {
        let baseComponents = URL(fileURLWithPath: basePath).standardized.pathComponents
        let targetComponents = URL(fileURLWithPath: targetPath).standardized.pathComponents

        guard targetComponents.starts(with: baseComponents) else { return false }

        // The system supplies the application-support base. Validate that base
        // and every directory below it, not unrelated ancestors such as `/`,
        // which is correctly owned by root and made every read fail.
        var directoryPaths = [URL(fileURLWithPath: basePath).standardized.path]
        var currentPath = directoryPaths[0]
        for component in targetComponents.dropFirst(baseComponents.count).dropLast() {
            currentPath = URL(fileURLWithPath: currentPath)
                .appendingPathComponent(component, isDirectory: true).path
            directoryPaths.append(currentPath)
        }

        for currentPath in directoryPaths {
            var st = stat()
            guard lstat(currentPath, &st) == 0 else { return false }
            // Must be directory
            guard (st.st_mode & S_IFMT) == S_IFDIR else { return false }
            // Must not be a symlink
            guard (st.st_mode & S_IFMT) != S_IFLNK else { return false }
            // Must be owned by current effective user
            guard st.st_uid == geteuid() else { return false }
            // Must not have group or other write permission
            guard (st.st_mode & 0o022) == 0 else { return false }
            // Must pass ACL safety check
            guard verifyACLSafety(path: currentPath) else { return false }
        }
        return true
    }

    /// Opens `filePath` securely using openat-style descriptor-relative relative traversal or descriptor checks.
    /// Ensures `O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`, checks `st_uid == geteuid()`, regular file,
    /// mode `st_mode & 022 == 0`, and reads at most `maxSize` bytes.
    static func readSecureFile(basePath: String, targetPath: String, maxSize: Int) -> Data? {
        guard verifyDirectoryChain(basePath: basePath, targetPath: targetPath) else { return nil }
        guard verifyACLSafety(path: targetPath) else { return nil }

        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        let fd = open(targetPath, flags)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        // Must be regular file
        guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        // Must be owned by effective user
        guard st.st_uid == geteuid() else { return nil }
        // No group/other write permissions
        guard (st.st_mode & 0o022) == 0 else { return nil }
        // Bounded size
        guard st.st_size <= maxSize else { return nil }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxSize {
            let toRead = min(buffer.count, maxSize - data.count)
            let bytesRead = read(fd, &buffer, toRead)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                break
            } else {
                if errno == EINTR { continue }
                return nil
            }
        }
        return data
    }
}

/// Persisted beside the app's other support files so calibration survives
/// restarts — the whole point is that it improves over weeks.
enum CalibrationStore {

    static var customApplicationSupportDirectory: URL?

    private static var appSupportBaseURL: URL {
        if let custom = customApplicationSupportDirectory {
            return custom
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var headroomDirectoryURL: URL {
        appSupportBaseURL.appendingPathComponent("Headroom", isDirectory: true)
    }

    static var url: URL {
        headroomDirectoryURL.appendingPathComponent("calibration.json")
    }

    static var legacyDirectoryURL: URL {
        appSupportBaseURL.appendingPathComponent("NotchGauge", isDirectory: true)
    }

    static var legacyURL: URL {
        legacyDirectoryURL.appendingPathComponent("calibration.json")
    }

    /// The app was called NotchGauge before it was called Headroom, so anyone
    /// who calibrated under the old name has a file in the old directory. Move it
    /// across once rather than silently starting them over — losing a saved
    /// calibration to a rename is exactly the kind of quiet data loss that a
    /// schema change already caused once in this project.
    private static func migrateLegacyStoreIfNeeded() {
        let fm = FileManager.default
        let destPath = url.path
        let legacyPath = legacyURL.path
        let basePath = appSupportBaseURL.path

        // If destination already exists, no migration needed
        guard !fm.fileExists(atPath: destPath) else { return }
        guard fm.fileExists(atPath: legacyPath) else { return }

        // Securely read from legacy descriptor
        guard let data = PosixSecurity.readSecureFile(basePath: basePath, targetPath: legacyPath, maxSize: PosixSecurity.maxCalibrationFileSize) else {
            return
        }

        // Validate decoded structure before publishing
        guard let _ = try? JSONDecoder().decode(Calibration.self, from: data) else {
            return
        }

        // Ensure target directory exists securely
        try? fm.createDirectory(at: headroomDirectoryURL, withIntermediateDirectories: true)

        // Write to a temporary file in the target directory first
        let tmpURL = headroomDirectoryURL.appendingPathComponent(".calibration.json.tmp.\(UUID().uuidString)")
        let tmpPath = tmpURL.path

        guard PosixSecurity.verifyDirectoryChain(basePath: basePath, targetPath: tmpPath) else { return }

        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let mode: mode_t = 0o600
        let fd = open(tmpPath, flags, mode)
        guard fd >= 0 else { return }

        var writeSuccess = false
        data.withUnsafeBytes { ptr in
            guard let baseAddr = ptr.baseAddress else { return }
            var written = 0
            let total = data.count
            while written < total {
                let bytesWritten = write(fd, baseAddr.advanced(by: written), total - written)
                if bytesWritten > 0 {
                    written += bytesWritten
                } else if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    break
                }
            }
            if written == total {
                writeSuccess = true
            }
        }
        close(fd)

        guard writeSuccess else {
            unlink(tmpPath)
            return
        }

        // Atomic publish using link or rename without replacing destination
        // POSIX rename replaces destination if it exists; to avoid replacing destination if another process created it:
        // On Unix/macOS, link(tmpPath, destPath) fails with EEXIST if destPath exists!
        if link(tmpPath, destPath) == 0 {
            unlink(tmpPath)
        } else {
            // link failed or destination already exists or filesystem doesn't support link
            unlink(tmpPath)
        }
    }

    static func load() -> Calibration {
        migrateLegacyStoreIfNeeded()
        let basePath = appSupportBaseURL.path
        let destPath = url.path
        if let data = PosixSecurity.readSecureFile(basePath: basePath, targetPath: destPath, maxSize: PosixSecurity.maxCalibrationFileSize),
           let c = try? JSONDecoder().decode(Calibration.self, from: data) {
            return c
        }
        return .seed
    }

    static func save(_ c: Calibration) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: headroomDirectoryURL, withIntermediateDirectories: true)

        let basePath = appSupportBaseURL.path
        let destPath = url.path
        let tmpURL = headroomDirectoryURL.appendingPathComponent(".calibration.json.tmp.\(UUID().uuidString)")
        let tmpPath = tmpURL.path

        guard PosixSecurity.verifyDirectoryChain(basePath: basePath, targetPath: tmpPath) else { return }

        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let mode: mode_t = 0o600
        let fd = open(tmpPath, flags, mode)
        guard fd >= 0 else { return }

        var writeSuccess = false
        data.withUnsafeBytes { ptr in
            guard let baseAddr = ptr.baseAddress else { return }
            var written = 0
            let total = data.count
            while written < total {
                let bytesWritten = write(fd, baseAddr.advanced(by: written), total - written)
                if bytesWritten > 0 {
                    written += bytesWritten
                } else if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    break
                }
            }
            if written == total {
                writeSuccess = true
            }
        }
        close(fd)

        guard writeSuccess else {
            unlink(tmpPath)
            return
        }

        rename(tmpPath, destPath)
    }
}
