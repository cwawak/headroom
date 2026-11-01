import Foundation

/// Antigravity usage provider and quota tracking.
///
/// Antigravity runs a local background language server listening on a dynamic
/// loopback HTTPS port. When running, it exposes Connect-RPC / gRPC-web endpoint
/// `/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
/// with CSRF protection (`X-Codeium-Csrf-Token`).
///
/// This endpoint returns server-authoritative percentages and reset timestamps
/// for rolling 5-hour and weekly quota windows across model groups (such as
/// "Gemini Models").
///
/// When Antigravity is active, Headroom queries this local daemon on loopback
/// (no tokens consumed, no credentials stored, no external network calls)
/// and watches `~/.gemini/antigravity/conversations` for activity.
final class AntigravityProvider: UsageProvider, @unchecked Sendable {

    let id: ProviderID = .antigravity

    private let lock = NSLock()

    // Cached probe state
    private var lastSnapshot: Snapshot?
    private var cachedPid: Int?
    private var cachedPort: Int?
    private var cachedCsrfToken: String?

    // Testing overrides
    var customHome: URL?
    var customInstall: Install?
    var customProbe: (@Sendable () -> ([QuotaWindow: Reading], Date?)?)?
    var customNow: Date?

    private var home: URL {
        customHome ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private var antigravityRoot: URL {
        home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
    }

    private var conversationsDir: URL {
        antigravityRoot.appendingPathComponent("conversations", isDirectory: true)
    }

    enum Install: Equatable {
        case none
        case installed(URL)
    }

    var install: Install {
        if let customInstall { return customInstall }
        let appSupport = home.appendingPathComponent("Library/Application Support/Antigravity", isDirectory: true)
        let candidates = [
            antigravityRoot,
            appSupport,
            URL(fileURLWithPath: "/Applications/Antigravity.app")
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return .installed(candidate)
            }
        }
        return .none
    }

    func isInstalled() -> Bool {
        if case .none = install { return false }
        return true
    }

    var canReportUsage: Bool {
        switch install {
        case .installed:
            return true
        case .none:
            return false
        }
    }

    func watchRoots() -> [URL] {
        if FileManager.default.fileExists(atPath: conversationsDir.path) {
            return [conversationsDir]
        }
        if case .installed(let url) = install {
            return [url]
        }
        return []
    }

    func snapshot() throws -> Snapshot {
        let now = customNow ?? Date()

        // Testing override
        if let customProbe {
            if let (readings, sourceDate) = customProbe() {
                return Snapshot(
                    provider: id,
                    readings: readings,
                    capturedAt: now,
                    sourceDate: sourceDate,
                    planLabel: "Antigravity",
                    rawWeighted: nil
                )
            } else {
                return Snapshot(
                    provider: id,
                    readings: Self.unavailable("Antigravity probe failed"),
                    capturedAt: now,
                    sourceDate: nil,
                    planLabel: "Antigravity",
                    rawWeighted: nil
                )
            }
        }

        guard isInstalled() else {
            return Snapshot(
                provider: id,
                readings: Self.unavailable("not installed"),
                capturedAt: now,
                sourceDate: nil,
                planLabel: nil,
                rawWeighted: nil
            )
        }

        lock.lock()
        defer { lock.unlock() }

        let sourceDate = newestConversationDate()

        // 1. Attempt probe to running local language server
        if let readings = probeLanguageServer() {
            let snap = Snapshot(
                provider: id,
                readings: readings,
                capturedAt: now,
                sourceDate: sourceDate ?? now,
                planLabel: "Antigravity",
                rawWeighted: nil
            )
            lastSnapshot = snap
            return snap
        }

        // 2. If daemon probe failed, check cached snapshot
        if let cached = lastSnapshot {
            if let resets = QuotaWindow.allCases.compactMap({ cached.readings[$0]?.resetsAt }).min(),
               resets <= now {
                return Snapshot(
                    provider: id,
                    readings: Self.unavailable("window reset — launch Antigravity to refresh"),
                    capturedAt: now,
                    sourceDate: nil,
                    planLabel: "Antigravity",
                    rawWeighted: nil
                )
            }
            return cached
        }

        // 3. No cache and daemon not responding
        return Snapshot(
            provider: id,
            readings: Self.unavailable("launch Antigravity to refresh"),
            capturedAt: now,
            sourceDate: nil,
            planLabel: "Antigravity",
            rawWeighted: nil
        )
    }

    // MARK: - Daemon Probing

    private func probeLanguageServer() -> [QuotaWindow: Reading]? {
        // Fast path: reuse cached pid, port, csrfToken if responsive
        if let port = cachedPort, let token = cachedCsrfToken {
            if let readings = queryQuota(port: port, csrfToken: token) {
                return readings
            }
        }

        // Scan processes for language_server
        guard let (pid, token) = findLanguageServer() else {
            cachedPid = nil
            cachedPort = nil
            cachedCsrfToken = nil
            return nil
        }

        let ports = findPorts(for: pid)
        for port in ports.prefix(20) {
            if let readings = queryQuota(port: port, csrfToken: token) {
                cachedPid = pid
                cachedPort = port
                cachedCsrfToken = token
                return readings
            }
        }

        return nil
    }

    private func queryQuota(port: Int, csrfToken: String) -> [QuotaWindow: Reading]? {
        guard let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = Data("{}".utf8)

        let delegate = LocalhostTrustDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5
        config.timeoutIntervalForResource = 1.0
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode: Int = 0

        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                responseData = data
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 0.6)

        guard statusCode == 200, let data = responseData else {
            return nil
        }

        return Self.parseQuotaSummary(data: data)
    }

    static func parseQuotaSummary(data: Data) -> [QuotaWindow: Reading]? {
        guard let response = try? JSONDecoder().decode(QuotaSummaryResponse.self, from: data),
              let groups = response.response?.groups, !groups.isEmpty else {
            return nil
        }

        // Prefer "Gemini Models", or group containing gemini, or first group with buckets
        let group = groups.first { $0.displayName?.localizedCaseInsensitiveContains("gemini") == true && ($0.buckets?.isEmpty == false) }
            ?? groups.first { $0.buckets?.isEmpty == false }
        guard let buckets = group?.buckets, !buckets.isEmpty else { return nil }

        var readings: [QuotaWindow: Reading] = [:]

        for bucket in buckets {
            let window: QuotaWindow?
            let windowStr = (bucket.window ?? "").lowercased()
            let bucketIdStr = (bucket.bucketId ?? "").lowercased()
            let displayNameStr = (bucket.displayName ?? "").lowercased()

            if windowStr.contains("5h") || bucketIdStr.contains("5h") || displayNameStr.contains("five hour") {
                window = .short
            } else if windowStr.contains("week") || bucketIdStr.contains("weekly") || displayNameStr.contains("weekly") {
                window = .long
            } else {
                window = nil
            }

            guard let targetWindow = window, let fraction = bucket.remainingFraction else { continue }

            let usedPercent = max(0.0, min(100.0, (1.0 - fraction) * 100.0))
            let resetDate = bucket.resetTime.flatMap { parseISO8601($0) }
            readings[targetWindow] = .authoritative(percent: usedPercent, resetsAt: resetDate)
        }

        guard !readings.isEmpty else { return nil }
        return readings
    }

    static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let d = formatter.date(from: string) { return d }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private func findLanguageServer() -> (pid: Int, csrfToken: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            for line in output.components(separatedBy: .newlines) {
                if line.contains("language_server") && line.contains("--csrf_token") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let tokens = trimmed.components(separatedBy: .whitespaces)
                    guard let pidStr = tokens.first, let pid = Int(pidStr) else { continue }

                    if let range = line.range(of: "--csrf_token") {
                        let remainder = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                        let token = remainder.components(separatedBy: .whitespaces).first ?? ""
                        if !token.isEmpty {
                            return (pid, token)
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func findPorts(for pid: Int) -> [Int] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-Pan", "-p", "\(pid)", "-i", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            var ports: [Int] = []
            for line in output.components(separatedBy: .newlines) {
                guard line.contains("127.0.0.1:") else { continue }
                if let range = line.range(of: "127.0.0.1:") {
                    let remainder = line[range.upperBound...]
                    let portStr = remainder.prefix { $0.isNumber }
                    if let port = Int(portStr), !ports.contains(port) {
                        ports.append(port)
                    }
                }
            }
            return ports
        } catch {
            return []
        }
    }

    private func newestConversationDate() -> Date? {
        guard FileManager.default.fileExists(atPath: conversationsDir.path) else { return nil }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var latest: Date?
        for url in contents where url.pathExtension == "db" || url.lastPathComponent.contains(".db") {
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate {
                if latest == nil || date > latest! {
                    latest = date
                }
            }
        }
        return latest
    }

    static func unavailable(_ reason: String) -> [QuotaWindow: Reading] {
        Dictionary(uniqueKeysWithValues: QuotaWindow.allCases.map { ($0, Reading.unavailable(reason: reason)) })
    }

    // MARK: - Response Model

    struct QuotaSummaryResponse: Decodable {
        struct Body: Decodable {
            struct Group: Decodable {
                let displayName: String?
                let description: String?
                let buckets: [Bucket]?
            }
            struct Bucket: Decodable {
                let bucketId: String?
                let displayName: String?
                let window: String?
                let remainingFraction: Double?
                let resetTime: String?
            }
            let groups: [Group]?
        }
        let response: Body?
    }
}

private final class LocalhostTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust,
           let host = challenge.protectionSpace.host as String?,
           (host == "127.0.0.1" || host == "localhost") {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
