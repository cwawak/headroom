import Foundation

/// Claude Code writes exact per-message token counts and never writes the limit
/// those counts are measured against, so this provider computes a numerator and
/// has to learn the denominator — see `Calibration`.
///
/// **Do not binary-search these files by timestamp.** An earlier version did, on
/// the assumption that an append-only JSONL transcript is chronological. It
/// isn't: measured on real data, 86% of records arrive out of order, with
/// backward jumps of up to 21 hours, because sidechains, resumed sessions and
/// compaction all interleave. The search landed near the end of the file and
/// silently under-counted the weekly total by 4.5x.
///
/// So instead: read each file once, then only the bytes appended since last time.
/// Ordering never matters, the first scan is the only expensive one, and a
/// refresh during a live session costs almost nothing.
final class ClaudeProvider: UsageProvider, @unchecked Sendable {

    let id: ProviderID = .claude

    private let lock = NSLock()

    private struct FileState {
        var inode: UInt64
        var offset: UInt64
        var leftover: Data = Data()
        var discardingOversizedLine: Bool = false
    }

    private var fileStates: [String: FileState] = [:]
    private var entries: [(date: Date, weight: Double)] = []
    /// Timestamped deduplication state: `requestId` mapped to record date.
    private var seenRequestIds: [String: Date] = [:]
    private var rejections: [(date: Date, window: QuotaWindow)] = []

    /// `(observed, window, fraction)`. Anthropic emits `utilization` only once you
    /// pass ~90% of a window, so this can't drive the gauge — but each one is an
    /// exact server-computed fraction, which makes it far better calibration data
    /// than waiting to be rejected outright.
    private var utilizations: [(date: Date, window: QuotaWindow, fraction: Double)] = []

    /// Ingestion status / diagnostics for incomplete reading.
    private var isIngestionIncomplete: Bool = false
    private var incompleteReason: String? = nil

    /// Keep a little more than a week so a calendar window near its boundary is
    /// still fully covered.
    private let retention: TimeInterval = 9 * 24 * 3600
    private static let sessionLength: TimeInterval = 5 * 3600
    private static let maxRecordSize: Int = 8 * 1024 * 1024 // 8 MiB max line size
    private static let readChunkSize: Int = 2 * 1024 * 1024 // 2 MiB read buffer

    /// Injectable properties for testing
    var customProjectsRoot: URL?
    var customAgentModeRoot: URL?
    var customNow: Date?

    private var projectsRoot: URL {
        customProjectsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private var agentModeRoot: URL {
        customAgentModeRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions",
                                    isDirectory: true)
    }

    private var sourceRoots: [URL] {
        var roots = [projectsRoot]
        if FileManager.default.fileExists(atPath: agentModeRoot.path) { roots.append(agentModeRoot) }
        return roots
    }

    func watchRoots() -> [URL] { sourceRoots }

    func isInstalled() -> Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: projectsRoot.path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    // MARK: - Weights

    private static let wInput = 1.0
    private static let wCacheWrite = 1.25
    private static let wCacheRead = 0.1
    private static let wOutput = 5.0

    private static func tierMultiplier(_ model: String?) -> Double {
        guard let m = model?.lowercased() else { return 1 }
        if m.contains("opus")   { return 3.0 }
        if m.contains("sonnet") { return 1.0 }
        if m.contains("haiku")  { return 0.3 }
        return 1
    }

    // MARK: - Snapshot

    func snapshot() throws -> Snapshot {
        guard isInstalled() else {
            return Snapshot(provider: id, readings: allUnavailable("Claude Code not installed"),
                            capturedAt: Date(), sourceDate: nil, planLabel: nil, rawWeighted: nil)
        }

        lock.lock()
        defer { lock.unlock() }

        let now = customNow ?? Date()
        let cutoff = now.addingTimeInterval(-retention)

        ingestNewBytes(now: now, cutoff: cutoff)

        // Prune retained usage entries and deduplication state consistently
        entries.removeAll { $0.date < cutoff }
        entries.sort { $0.date < $1.date }

        // Filter dictionary without mutating during iteration
        seenRequestIds = seenRequestIds.filter { $0.value >= cutoff }

        if isIngestionIncomplete, let reason = incompleteReason {
            return Snapshot(provider: id, readings: allUnavailable("Claude usage incomplete: \(reason)"),
                            capturedAt: now, sourceDate: entries.last?.date, planLabel: nil, rawWeighted: nil)
        }

        var calibration = CalibrationStore.load()

        let session = currentSession(now: now)
        let weekStart = weeklyWindowStart(now: now, calibration: calibration)
        let weekSum = entries.filter { $0.date >= weekStart }.reduce(0) { $0 + $1.weight }

        learn(&calibration, sessionSum: session.sum, weekSum: weekSum, weekStart: weekStart)

        var readings: [QuotaWindow: Reading] = [:]
        readings[.short] = reading(sum: session.sum, window: .short,
                                   calibration: calibration, resetsAt: session.resetsAt)
        readings[.long] = reading(sum: weekSum, window: .long,
                                  calibration: calibration,
                                  resetsAt: weekStart.addingTimeInterval(7 * 24 * 3600))

        return Snapshot(provider: id,
                        readings: readings,
                        capturedAt: now,
                        sourceDate: entries.last?.date,
                        planLabel: calibration.shortObservations > 0 ? "calibrated" : "estimated",
                        rawWeighted: [.short: session.sum, .long: weekSum])
    }

    // MARK: - Windows

    private func currentSession(now: Date) -> (sum: Double, resetsAt: Date?) {
        var blockStart: Date?
        var sum = 0.0
        for e in entries {
            if let start = blockStart, e.date < start.addingTimeInterval(Self.sessionLength) {
                sum += e.weight
            } else {
                blockStart = e.date
                sum = e.weight
            }
        }
        guard let start = blockStart else { return (0, nil) }
        let resets = start.addingTimeInterval(Self.sessionLength)
        return now >= resets ? (0, nil) : (sum, resets)
    }

    private func weeklyWindowStart(now: Date, calibration: Calibration) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.weekday = calibration.weeklyResetWeekday
        components.hour = calibration.weeklyResetHour
        components.minute = 0
        components.second = 0
        return calendar.nextDate(after: now, matching: components,
                                 matchingPolicy: .nextTimePreservingSmallerComponents,
                                 direction: .backward)
            ?? now.addingTimeInterval(-7 * 24 * 3600)
    }

    private func sessionSum(at t: Date) -> Double {
        var blockStart: Date?
        var sum = 0.0
        for e in entries where e.date <= t {
            if let s = blockStart, e.date < s.addingTimeInterval(Self.sessionLength) {
                sum += e.weight
            } else {
                blockStart = e.date
                sum = e.weight
            }
        }
        return sum
    }

    private func weekSum(at t: Date, calibration: Calibration) -> Double {
        let start = weeklyWindowStart(now: t, calibration: calibration)
        return entries.filter { $0.date >= start && $0.date <= t }.reduce(0) { $0 + $1.weight }
    }

    // MARK: - Calibration from observed rejections

    private func learn(_ calibration: inout Calibration,
                       sessionSum: Double, weekSum: Double, weekStart: Date) {
        var changed = false
        var newest = calibration.lastRejectionFolded
        for r in rejections {
            guard r.date.timeIntervalSince1970 > calibration.lastRejectionFolded else { continue }
            let span: TimeInterval = r.window == .short ? Self.sessionLength : 7 * 24 * 3600
            let from = r.date.addingTimeInterval(-span)
            guard let oldest = entries.first?.date, from >= oldest else { continue }
            let observed = entries
                .filter { $0.date >= from && $0.date <= r.date }
                .reduce(0) { $0 + $1.weight }
            guard observed > 0 else { continue }
            calibration.fold(observed, into: r.window)
            newest = max(newest, r.date.timeIntervalSince1970)
            changed = true
        }
        rejections.removeAll()
        if changed { calibration.lastRejectionFolded = newest }

        var newestUtil = calibration.lastUtilizationFolded
        for u in utilizations {
            guard u.date.timeIntervalSince1970 > calibration.lastUtilizationFolded else { continue }
            let span: TimeInterval = u.window == .short ? Self.sessionLength : 7 * 24 * 3600
            guard let oldest = entries.first?.date,
                  u.date.addingTimeInterval(-span) >= oldest else { continue }
            let measured = u.window == .short ? self.sessionSum(at: u.date)
                                              : self.weekSum(at: u.date, calibration: calibration)
            guard measured > 0 else { continue }
            calibration.fold(measured / u.fraction, into: u.window)
            newestUtil = max(newestUtil, u.date.timeIntervalSince1970)
            changed = true
        }
        utilizations.removeAll()
        calibration.lastUtilizationFolded = newestUtil

        if changed { CalibrationStore.save(calibration) }
    }

    private func reading(sum: Double, window: QuotaWindow,
                         calibration: Calibration, resetsAt: Date?) -> Reading {
        let capacity = calibration.capacity(for: window)
        guard capacity > 0 else { return .unavailable(reason: "not calibrated") }
        return .estimated(percent: min(100, max(0, sum / capacity * 100)),
                          confidence: calibration.confidence(for: window),
                          resetsAt: resetsAt)
    }

    private func allUnavailable(_ reason: String) -> [QuotaWindow: Reading] {
        Dictionary(uniqueKeysWithValues: QuotaWindow.allCases.map { ($0, .unavailable(reason: reason)) })
    }

    // MARK: - Incremental ingest & Path Security

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let quotaMarker = Data("quotaLimits".utf8)
    private static let rateInfoMarker = Data("rate_limit_info".utf8)

    private func validateSourceRoot(_ root: URL) -> Bool {
        let path = root.path
        var st = stat()
        if lstat(path, &st) != 0 {
            return false
        }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            isIngestionIncomplete = true
            incompleteReason = "source root is a symbolic link: \(path)"
            return false
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            return false
        }
        return true
    }

    private static func isSecureChild(baseRoot: String, candidatePath: String) -> Bool {
        let baseComponents = URL(fileURLWithPath: baseRoot).standardized.pathComponents
        let candComponents = URL(fileURLWithPath: candidatePath).standardized.pathComponents
        guard candComponents.count >= baseComponents.count else { return false }
        for i in 0..<baseComponents.count {
            if baseComponents[i] != candComponents[i] { return false }
        }
        return true
    }

    private func ingestNewBytes(now: Date, cutoff: Date) {
        let fm = FileManager.default

        for root in sourceRoots {
            guard validateSourceRoot(root) else { continue }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let item = enumerator.nextObject() {
                guard let url = item as? URL else { continue }
                guard url.pathExtension == "jsonl" else { continue }

                let candidatePath = url.path
                guard Self.isSecureChild(baseRoot: root.path, candidatePath: candidatePath) else {
                    isIngestionIncomplete = true
                    incompleteReason = "path traversal outside root: \(candidatePath)"
                    continue
                }

                ingestFile(at: candidatePath, now: now, cutoff: cutoff)
            }
        }
    }

    private func ingestFile(at path: String, now: Date, cutoff: Date) {
        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        let fd = open(path, flags)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { return }

        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return
        }

        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtime))
        if mtime < cutoff {
            return
        }

        let size = UInt64(st.st_size)
        let inode = UInt64(st.st_ino)

        var state = fileStates[path] ?? FileState(inode: inode, offset: 0)

        // Rotation or truncation check
        if state.inode != inode || size < state.offset {
            state = FileState(inode: inode, offset: 0)
        }

        guard size > state.offset else {
            fileStates[path] = state
            return
        }

        let targetOffset = size
        var currentOffset = state.offset

        if lseek(fd, off_t(currentOffset), SEEK_SET) < 0 {
            fileStates[path] = state
            return
        }

        var chunkBuffer = [UInt8](repeating: 0, count: Self.readChunkSize)

        while currentOffset < targetOffset {
            let bytesToRead = min(Int(targetOffset - currentOffset), Self.readChunkSize)
            let bytesRead = read(fd, &chunkBuffer, bytesToRead)

            if bytesRead <= 0 {
                if bytesRead < 0 && errno == EINTR { continue }
                isIngestionIncomplete = true
                incompleteReason = "read error or truncation on file: \(path)"
                break
            }

            let chunkData = Data(bytes: chunkBuffer, count: bytesRead)
            let chunkStartOffset = currentOffset
            currentOffset += UInt64(bytesRead)

            // Process buffer with leftover
            var buffer = state.leftover + chunkData
            state.leftover = Data()

            var searchIndex = 0

            while searchIndex < buffer.count {
                if state.discardingOversizedLine {
                    if let newlineRel = buffer[searchIndex...].firstIndex(of: 0x0A) {
                        searchIndex = newlineRel + 1
                        state.discardingOversizedLine = false
                        // Update offset to end of discarded line
                        if searchIndex >= (buffer.count - chunkData.count) {
                            let consumedInChunk = searchIndex - (buffer.count - chunkData.count)
                            state.offset = chunkStartOffset + UInt64(consumedInChunk)
                        }
                    } else {
                        searchIndex = buffer.count
                        state.offset = currentOffset
                    }
                } else {
                    if let newlineRel = buffer[searchIndex...].firstIndex(of: 0x0A) {
                        let line = buffer[searchIndex..<newlineRel]
                        if line.count > Self.maxRecordSize {
                            isIngestionIncomplete = true
                            incompleteReason = "oversized log record (>8 MiB) in \(path)"
                        } else {
                            parseLine(line, now: now, cutoff: cutoff)
                        }
                        searchIndex = newlineRel + 1
                        if searchIndex >= (buffer.count - chunkData.count) {
                            let consumedInChunk = searchIndex - (buffer.count - chunkData.count)
                            state.offset = chunkStartOffset + UInt64(consumedInChunk)
                        }
                    } else {
                        let remaining = buffer[searchIndex...]
                        if remaining.count > Self.maxRecordSize {
                            isIngestionIncomplete = true
                            incompleteReason = "oversized log record (>8 MiB) in \(path)"
                            state.discardingOversizedLine = true
                            searchIndex = buffer.count
                            state.offset = currentOffset
                        } else {
                            state.leftover = Data(remaining)
                            searchIndex = buffer.count
                        }
                    }
                }
            }
        }

        fileStates[path] = state
    }

    private func parseLine(_ lineSlice: Data.SubSequence, now: Date, cutoff: Date) {
        let data = Data(lineSlice)
        guard !data.isEmpty else { return }

        let hasUsage = data.range(of: Self.usageMarker) != nil
        let hasQuota = data.range(of: Self.quotaMarker) != nil
                    || data.range(of: Self.rateInfoMarker) != nil
        guard hasUsage || hasQuota else { return }

        let decoder = JSONDecoder()
        guard let row = try? decoder.decode(ClaudeRow.self, from: data),
              let date = row.date else { return }

        if date < cutoff {
            return
        }

        if date > now.addingTimeInterval(300) {
            isIngestionIncomplete = true
            incompleteReason = "implausibly future-dated log record: \(date)"
            return
        }

        if let quota = row.quotaLimits, quota.status == "rejected", let w = quota.window {
            rejections.append((date, w))
        }
        if let info = row.rateLimitInfo {
            if info.status == "rejected", let w = info.window { rejections.append((date, w)) }
            if let u = info.utilization, u > 0.05, u <= 1.5, let w = info.window {
                utilizations.append((date, w, u))
            }
        }
        guard let usage = row.message?.usage else { return }

        if let rid = row.requestId ?? row.uuid {
            if seenRequestIds[rid] != nil {
                return // Deduplicated
            }
            seenRequestIds[rid] = date
        }
        entries.append((date, weight(of: usage, model: row.message?.model)))
    }

    private func weight(of u: ClaudeUsage, model: String?) -> Double {
        let base = Double(u.inputTokens ?? 0) * Self.wInput
            + Double(u.cacheCreationInputTokens ?? 0) * Self.wCacheWrite
            + Double(u.cacheReadInputTokens ?? 0) * Self.wCacheRead
            + Double(u.outputTokens ?? 0) * Self.wOutput
        return base * Self.tierMultiplier(model)
    }
}

// MARK: - Wire format

private struct ClaudeRow: Decodable {
    let timestamp: String?
    let requestId: String?
    let uuid: String?
    let message: ClaudeMessage?
    let quotaLimits: ClaudeQuota?
    let rateLimitInfo: ClaudeRateLimitInfo?

    enum CodingKeys: String, CodingKey {
        case timestamp, requestId, uuid, message, quotaLimits
        case rateLimitInfo = "rate_limit_info"
    }

    var date: Date? {
        guard let timestamp else { return nil }
        return ISO8601DateFormatter.withFractional.date(from: timestamp)
            ?? ISO8601DateFormatter.plain.date(from: timestamp)
    }
}

private struct ClaudeMessage: Decodable {
    let model: String?
    let usage: ClaudeUsage?
}

struct ClaudeUsage: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

private struct ClaudeRateLimitInfo: Decodable {
    let status: String?
    let rateLimitType: String?
    let utilization: Double?

    var window: QuotaWindow? {
        switch rateLimitType {
        case "five_hour": return .short
        case "weekly", "opus_weekly", "seven_day": return .long
        default: return nil
        }
    }
}

private struct ClaudeQuota: Decodable {
    let status: String?
    let rateLimitType: String?
    let resetsAt: Double?

    var window: QuotaWindow? {
        switch rateLimitType {
        case "five_hour": return .short
        case "weekly", "opus_weekly": return .long
        default: return nil
        }
    }
}
