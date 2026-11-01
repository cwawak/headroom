import Foundation

/// Antigravity detection and quota tracking.
///
/// Antigravity is Google's IDE located under `~/.gemini/antigravity` or within
/// application state. While active sessions may expose local server ports or store
/// modelCredits in `state.vscdb`, disk-persisted percentage quotas are not stored
/// offline.
///
/// This provider detects Antigravity installation and session roots honestly,
/// reporting clear status without inventing numbers.
struct AntigravityProvider: UsageProvider {

    let id: ProviderID = .antigravity

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var antigravityRoot: URL {
        home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
    }

    enum Install {
        case none
        case installed(URL)
    }

    var install: Install {
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

    var canReportUsage: Bool { false }

    func watchRoots() -> [URL] {
        if case .installed(let url) = install {
            return [url]
        }
        return []
    }

    func snapshot() throws -> Snapshot {
        let reason: String
        switch install {
        case .none:
            reason = "not installed"
        case .installed:
            reason = "usage not stored on disk"
        }
        return Snapshot(
            provider: id,
            readings: Dictionary(uniqueKeysWithValues:
                QuotaWindow.allCases.map { ($0, Reading.unavailable(reason: reason)) }),
            capturedAt: Date(),
            sourceDate: nil,
            planLabel: nil,
            rawWeighted: nil
        )
    }
}
