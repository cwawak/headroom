import Foundation
import Darwin

/// Uses Codex's own authenticated, read-only usage RPC. Headroom never reads
/// credentials and never starts a thread or turn. Codex handles the HTTPS call.
final class CodexUsageClient: @unchecked Sendable {
    static let shared = CodexUsageClient()

    struct Sample {
        let limits: RateLimits
        let date: Date
        let isCached: Bool
    }

    enum ClientError: Error {
        case cliUnavailable, invalidResponse, requestFailed, timedOut
    }

    private let lock = NSLock()
    private let fetch: @Sendable () throws -> RateLimits
    private var lastAttempt: Date?
    private var lastAttemptSucceeded = false
    private var sample: Sample?

    init(fetch: @escaping @Sendable () throws -> RateLimits = {
        guard let executable = CodexUsageClient.executable() else { throw ClientError.cliUnavailable }
        return try CodexUsageClient.request(executable: executable)
    }) {
        self.fetch = fetch
    }

    /// Coalesces overlapping scans and backs off on failure as well as success.
    /// The existing five-minute safety timer also refreshes usage while idle.
    func latest(now: Date = Date()) -> Sample? {
        lock.lock()
        defer { lock.unlock() }
        if lastAttempt == nil || now.timeIntervalSince(lastAttempt!) >= 60 {
            lastAttempt = now
            do {
                let limits = try fetch()
                sample = Sample(limits: limits, date: now, isCached: false)
                lastAttemptSucceeded = true
            } catch {
                lastAttemptSucceeded = false
            }
        }
        guard let sample else { return nil }
        return Sample(limits: sample.limits, date: sample.date, isCached: !lastAttemptSucceeded)
    }

    private static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // GUI apps do not inherit the user's interactive shell PATH.
        let candidates = [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".codex/packages/standalone/current/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func request(executable: URL, timeout: TimeInterval = 10) throws -> RateLimits {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        // Do not surface auth diagnostics, tokens, or unrelated CLI logs.
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                for _ in 0..<20 where process.isRunning { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
        }

        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw ClientError.requestFailed }
        // A CLI that exits during startup must not kill the menu bar app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send([
            "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "headroom", "version": "1.0"]]
        ])

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pending = Data()
        var totalBytes = 0
        var initialized = false
        var bytes = [UInt8](repeating: 0, count: 8192)
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 50)
            if result < 0 {
                if errno == EINTR { continue }
                throw ClientError.requestFailed
            }
            guard result > 0 else { continue }
            let count = read(fd, &bytes, bytes.count)
            if count == 0 { throw ClientError.requestFailed }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw ClientError.requestFailed
            }
            totalBytes += count
            guard totalBytes <= 1024 * 1024 else { throw ClientError.invalidResponse }
            pending.append(contentsOf: bytes.prefix(count))
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                guard message["error"] == nil else { throw ClientError.requestFailed }
                if id == 1 && !initialized {
                    guard message["result"] != nil else { throw ClientError.invalidResponse }
                    initialized = true
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2 && initialized {
                    guard let result = message["result"] else { throw ClientError.invalidResponse }
                    return try decode(JSONSerialization.data(withJSONObject: result))
                }
            }
        }
        throw ClientError.timedOut
    }

    static func decode(_ data: Data) throws -> RateLimits {
        struct Response: Decodable {
            let rateLimits: RateLimits
            let rateLimitsByLimitId: [String: RateLimits]?
            let rateLimitResetCredits: RateLimitResetCredits?
        }
        // The app-server RPC uses camelCase; rollout JSONL uses snake_case.
        let response = try JSONDecoder().decode(Response.self, from: data)
        let limits = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        guard limits.limitId == nil || limits.limitId == "codex",
              [limits.primary, limits.secondary].compactMap({ $0 }).contains(where: {
                  $0.usedPercent?.isFinite == true && [300, 10_080].contains($0.windowMinutes ?? 0)
              }) else { throw ClientError.invalidResponse }
        return RateLimits(limitId: limits.limitId, planType: limits.planType,
                          primary: limits.primary, secondary: limits.secondary,
                          bankedResets: limits.bankedResets,
                          rateLimitResetCredits: response.rateLimitResetCredits ?? limits.rateLimitResetCredits)
    }
}
