import XCTest
@testable import Headroom

final class UsageProviderTests: XCTestCase {

    /// Dummy struct conforming to `UsageProvider` without overriding `canReportUsage`.
    /// Used to test the protocol extension's default implementation.
    private struct DefaultUsageProvider: UsageProvider {
        let id: ProviderID = .codex

        func watchRoots() -> [URL] {
            []
        }

        func isInstalled() -> Bool {
            true
        }

        func snapshot() throws -> Snapshot {
            Snapshot(
                provider: id,
                readings: [:],
                capturedAt: Date(),
                sourceDate: nil,
                planLabel: nil,
                rawWeighted: nil
            )
        }
    }

    /// Dummy struct conforming to `UsageProvider` that explicitly overrides `canReportUsage`.
    private struct CustomUnreportableUsageProvider: UsageProvider {
        let id: ProviderID = .gemini

        var canReportUsage: Bool {
            false
        }

        func watchRoots() -> [URL] {
            []
        }

        func isInstalled() -> Bool {
            true
        }

        func snapshot() throws -> Snapshot {
            Snapshot(
                provider: id,
                readings: [:],
                capturedAt: Date(),
                sourceDate: nil,
                planLabel: nil,
                rawWeighted: nil
            )
        }
    }

    func testDefaultCanReportUsageReturnsTrue() {
        let provider = DefaultUsageProvider()
        XCTAssertTrue(provider.canReportUsage, "Default implementation of UsageProvider.canReportUsage should return true")
    }

    func testOverriddenCanReportUsageReturnsFalse() {
        let provider = CustomUnreportableUsageProvider()
        XCTAssertFalse(provider.canReportUsage, "Overridden UsageProvider.canReportUsage should return false")
    }

    func testConcreteProvidersCanReportUsageValues() {
        let codex = CodexProvider()
        XCTAssertTrue(codex.canReportUsage, "CodexProvider should return true for default canReportUsage")

        let claude = ClaudeProvider()
        XCTAssertTrue(claude.canReportUsage, "ClaudeProvider should return true for default canReportUsage")

        let gemini = GeminiProvider()
        XCTAssertFalse(gemini.canReportUsage, "GeminiProvider should return false for custom canReportUsage")
    }
}
