import Foundation

/// Reads current usage through Codex, falling back to timestamped rollout events.
///
/// Two things make this non-obvious, both learned the hard way from real files:
///
/// 1. Session files get enormous (72 MB observed). Never parse forward — seek to
///    the end and walk backward.
/// 2. Codex emits more than one kind of `rate_limits`. `limit_id: "codex"` carries
///    the `primary`/`secondary` percentages; `limit_id: "premium"` carries credits
///    and leaves both **null**. Taking the last `token_count` event therefore shows
///    an empty gauge about as often as not. Only Codex buckets with a recognized
///    quota window are usable.
final class CodexProvider: UsageProvider, @unchecked Sendable {

    let id: ProviderID = .codex

    var customSessionsRoot: URL?

    private let lock = NSLock()
    private var cachedFiles: [URL: CachedFile] = [:]

    private struct CachedFile {
        let modified: Date
        let size: Int
        let hit: Hit?
    }

    private var sessionsRoot: URL {
        customSessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func watchRoots() -> [URL] { [sessionsRoot] }

    func isInstalled() -> Bool {
        var st = stat()
        guard lstat(sessionsRoot.path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard (st.st_mode & S_IFMT) != S_IFLNK else { return false }
        guard st.st_uid == geteuid() else { return false }
        guard (st.st_mode & 0o022) == 0 else { return false }
        guard PosixSecurity.verifyACLSafety(path: sessionsRoot.path) else { return false }
        return true
    }

    func snapshot() throws -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        // Fixture roots must never consult the user's real account.
        let live = customSessionsRoot == nil ? CodexUsageClient.shared.latest() : nil
        if let live, !live.isCached {
            return snapshot(from: live.limits, date: live.date, isCached: false)
        }
        guard isInstalled() else {
            return Snapshot(provider: id, readings: Self.unavailable("Codex not installed"),
                            capturedAt: Date(), sourceDate: nil, planLabel: nil, rawWeighted: nil)
        }
        let files = newestRollouts()
        guard !files.isEmpty || live != nil else {
            return Snapshot(provider: id, readings: Self.unavailable("No sessions yet"),
                            capturedAt: Date(), sourceDate: nil, planLabel: nil, rawWeighted: nil)
        }
        // A touched/resumed file can contain a quota event much older than its
        // mtime. Compare event timestamps across files, including files beyond
        // the old five-candidate limit. Cache tails so unchanged files are cheap.
        var found = live.map { Hit(limits: $0.limits, date: $0.date) }
        let fileSet = Set(files)
        cachedFiles = cachedFiles.filter { fileSet.contains($0.key) }
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            let hit: Hit?
            if let cached = cachedFiles[file], cached.modified == modified, cached.size == size {
                hit = cached.hit
            } else {
                hit = try? lastQuotaEvent(in: file)
                cachedFiles[file] = CachedFile(modified: modified, size: size, hit: hit)
            }
            if let hit, found == nil || hit.date > found!.date { found = hit }
        }
        guard let hit = found else {
            return Snapshot(provider: id, readings: Self.unavailable("No quota event in recent sessions"),
                            capturedAt: Date(), sourceDate: nil, planLabel: nil, rawWeighted: nil)
        }

        return snapshot(from: hit.limits, date: hit.date,
                        isCached: Date().timeIntervalSince(hit.date) > 1800 || live?.isCached == true)
    }

    private func snapshot(from limits: RateLimits, date: Date, isCached: Bool) -> Snapshot {
        let readings = Self.readings(from: limits)

        let banked = limits.bankedResets ?? limits.rateLimitResetCredits?.availableCount

        return Snapshot(provider: id,
                        readings: readings,
                        capturedAt: Date(),
                        sourceDate: date,
                        planLabel: limits.planType,
                        rawWeighted: nil,
                        bankedResets: banked,
                        isCached: isCached)
    }

    // MARK: - Mapping

    static func readings(from limits: RateLimits, now: Date = Date()) -> [QuotaWindow: Reading] {
        var readings = unavailable("not reported by Codex")
        for rateWindow in [limits.primary, limits.secondary].compactMap({ $0 }) {
            let quotaWindow: QuotaWindow
            switch rateWindow.windowMinutes {
            case 5 * 60:
                quotaWindow = .short
            case 7 * 24 * 60:
                quotaWindow = .long
            default:
                continue
            }
            readings[quotaWindow] = reading(from: rateWindow, now: now)
        }
        return readings
    }

    private static func reading(from w: RateWindow, now: Date) -> Reading {
        guard let pct = w.usedPercent else { return .unavailable(reason: "not reported") }
        let reset = w.resetsAt.map { Date(timeIntervalSince1970: $0) }

        // These logs only advance while Codex is running. Once `resetsAt` passes,
        // the window has rolled over server-side and the number on disk is not
        // just stale — it is wrong in the dangerous direction. A cached 100%
        // would say "you are blocked" to someone with a full fresh window.
        // We can't know the new value until Codex next writes, so say so.
        if let reset, reset <= now {
            return .unavailable(reason: "window reset — run Codex to refresh")
        }

        // Codex computes this server-side. It is a fact, not an inference.
        return .authoritative(percent: max(0, min(100, pct)), resetsAt: reset)
    }

    private static func unavailable(_ reason: String) -> [QuotaWindow: Reading] {
        Dictionary(uniqueKeysWithValues: QuotaWindow.allCases.map { ($0, .unavailable(reason: reason)) })
    }

    // MARK: - Finding the newest session

    /// Discover all day directories: resumed sessions keep their original path.
    /// Modification time orders work, but never determines quota freshness.
    private func newestRollouts() -> [URL] {
        let fm = FileManager.default
        let rootPath = sessionsRoot.path

        func kids(_ url: URL) -> [URL] {
            guard PosixSecurity.verifyDirectoryChain(basePath: rootPath, targetPath: url.path) else { return [] }
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            return items
                .filter { item in
                    guard PosixSecurity.verifyDirectoryChain(basePath: rootPath, targetPath: item.path) else { return false }
                    return (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }

        let days = kids(sessionsRoot).flatMap(kids).flatMap(kids)

        var candidates: [(url: URL, modified: Date)] = []
        for day in days {
            guard PosixSecurity.verifyDirectoryChain(basePath: rootPath, targetPath: day.path) else { continue }
            let files = ((try? fm.contentsOfDirectory(at: day,
                            includingPropertiesForKeys: [.contentModificationDateKey],
                            options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
            for f in files {
                guard PosixSecurity.verifyDirectoryChain(basePath: rootPath, targetPath: f.path) else { continue }
                guard PosixSecurity.verifyACLSafety(path: f.path) else { continue }
                var st = stat()
                guard lstat(f.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                      st.st_uid == geteuid(), (st.st_mode & 0o022) == 0 else { continue }
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append((f, m))
            }
        }
        return candidates.sorted { $0.modified > $1.modified }.map(\.url)
    }

    // MARK: - Reverse tail

    private struct Hit { let limits: RateLimits; let date: Date }

    private static let marker = Data("token_count".utf8)

    private func lastQuotaEvent(in url: URL) throws -> Hit? {
        let rootPath = sessionsRoot.path
        guard PosixSecurity.verifyDirectoryChain(basePath: rootPath, targetPath: url.path) else { return nil }
        guard PosixSecurity.verifyACLSafety(path: url.path) else { return nil }

        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        let fd = open(url.path, flags)
        guard fd >= 0 else { return nil }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            return nil
        }

        guard (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }

        guard st.st_uid == geteuid() else {
            close(fd)
            return nil
        }

        guard (st.st_mode & 0o022) == 0 else {
            close(fd)
            return nil
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        guard size > 0 else { return nil }

        var window: UInt64 = 256 * 1024
        let ceiling: UInt64 = 8 * 1024 * 1024

        while true {
            let take = min(window, size)
            try handle.seek(toOffset: size - take)
            guard var data = try handle.read(upToCount: Int(take)), !data.isEmpty else { return nil }

            // If we started mid-file we almost certainly cut a line in half; drop it.
            if take < size, let nl = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: (nl + 1)..<data.endIndex)
            }
            if let hit = scanBackward(data) { return hit }

            if take >= size || window >= ceiling { return nil }
            window *= 4
        }
    }

    private func scanBackward(_ blob: Data) -> Hit? {
        let lines = blob.split(separator: 0x0A, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for line in lines.reversed() {
            // Cheap byte test before paying for Data allocation and JSON decoding on a 72 MB file's worth of lines.
            guard line.firstRange(of: Self.marker) != nil else { continue }
            let data = Data(line)
            guard let row = try? decoder.decode(RolloutLine.self, from: data),
                  row.payload?.type == "token_count",
                  let limits = row.payload?.rateLimits,
                  limits.limitId == nil || limits.limitId == "codex",
                  [limits.primary, limits.secondary].compactMap({ $0 }).contains(where: {
                      $0.usedPercent != nil && [300, 10_080].contains($0.windowMinutes ?? 0)
                  }),
                  let date = row.date
            else { continue }
            return Hit(limits: limits, date: date)
        }
        return nil
    }
}

// MARK: - Wire format

private struct RolloutLine: Decodable {
    let timestamp: String?
    let payload: Payload?

    var date: Date? {
        guard let timestamp else { return nil }
        return ISO8601DateFormatter.withFractional.date(from: timestamp)
            ?? ISO8601DateFormatter.plain.date(from: timestamp)
    }
}

private struct Payload: Decodable {
    let type: String?
    let rateLimits: RateLimits?
}

struct RateLimits: Decodable, Sendable {
    let limitId: String?
    let planType: String?
    let primary: RateWindow?
    let secondary: RateWindow?
    let bankedResets: Int?
    let rateLimitResetCredits: RateLimitResetCredits?

    init(
        limitId: String? = nil,
        planType: String? = nil,
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        bankedResets: Int? = nil,
        rateLimitResetCredits: RateLimitResetCredits? = nil
    ) {
        self.limitId = limitId
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.bankedResets = bankedResets
        self.rateLimitResetCredits = rateLimitResetCredits
    }
}

struct RateLimitResetCredits: Decodable, Sendable {
    let availableCount: Int?
}

struct RateWindow: Decodable, Sendable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Double?

    init(usedPercent: Double?, windowMinutes: Int?, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent, windowMinutes, windowDurationMins, resetsAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try values.decodeIfPresent(Double.self, forKey: .usedPercent)
        // RPC and rollout records use different names for the same duration.
        windowMinutes = try values.decodeIfPresent(Int.self, forKey: .windowMinutes)
            ?? values.decodeIfPresent(Int.self, forKey: .windowDurationMins)
        resetsAt = try values.decodeIfPresent(Double.self, forKey: .resetsAt)
    }
}

extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()
}
