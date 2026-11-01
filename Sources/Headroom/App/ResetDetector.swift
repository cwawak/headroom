import Foundation
import UserNotifications

/// Detects resets in quota windows (normal and abnormal/free resets) and posts notifications.
final class ResetDetector: @unchecked Sendable {

    enum ResetType {
        case normal(provider: ProviderID, window: QuotaWindow)
        case abnormalFreeReset(provider: ProviderID, window: QuotaWindow, dropPercent: Double)
    }

    private var previousReadings: [ProviderID: [QuotaWindow: (usedPercent: Double, resetsAt: Date?)]] = [:]
    private let center: UNUserNotificationCenter?
    private let onNotification: (@Sendable (ResetType) -> Void)?

    convenience init() {
        let center: UNUserNotificationCenter?
        if Bundle.main.bundleIdentifier != nil {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }
        self.init(center: center, onNotification: nil)
    }

    init(center: UNUserNotificationCenter?, onNotification: (@Sendable (ResetType) -> Void)? = nil) {
        self.center = center
        self.onNotification = onNotification
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func inspect(snapshots: [ProviderID: Snapshot], now: Date = Date()) -> [ResetType] {
        var detected: [ResetType] = []

        for (provider, snap) in snapshots {
            var prevMap = previousReadings[provider] ?? [:]

            for window in QuotaWindow.allCases {
                guard let reading = snap.readings[window],
                      let currentUsed = reading.percentUsed else { continue }
                let currentResetsAt = reading.resetsAt

                if let prev = prevMap[window] {
                    // 1. Detect scheduled window rollover independently of percentage comparison:
                    // If resetsAt advanced to a later time, or if the scheduled reset timestamp has passed
                    let resetRolledOver: Bool
                    if let prevReset = prev.resetsAt {
                        if let curReset = currentResetsAt, curReset > prevReset {
                            resetRolledOver = true
                        } else if now >= prevReset && currentUsed < prev.usedPercent {
                            resetRolledOver = true
                        } else {
                            resetRolledOver = false
                        }
                    } else {
                        resetRolledOver = false
                    }

                    if resetRolledOver {
                        detected.append(.normal(provider: provider, window: window))
                    } else if reading.isExact && currentUsed < prev.usedPercent {
                        // 2. Restrict free quota reset detection to authoritative readings (Codex).
                        // Calibrating Claude or adjusting estimations must not trigger a false "Free Quota Reset".
                        let drop = prev.usedPercent - currentUsed
                        if drop >= 5.0 {
                            detected.append(.abnormalFreeReset(provider: provider, window: window, dropPercent: drop))
                        }
                    }
                }

                prevMap[window] = (usedPercent: currentUsed, resetsAt: currentResetsAt)
            }

            previousReadings[provider] = prevMap
        }

        for reset in detected {
            postNotification(for: reset)
        }

        return detected
    }

    private func postNotification(for reset: ResetType) {
        onNotification?(reset)
        guard let center else { return }

        let content = UNMutableNotificationContent()
        switch reset {
        case .normal(let provider, let window):
            content.title = "\(provider.displayName) Quota Reset"
            content.body = "Your \(window.shortLabel) quota has rolled over and reset."
        case .abnormalFreeReset(let provider, let window, let drop):
            content.title = "\(provider.displayName) Free Quota Reset!"
            content.body = "Early/free reset detected outside normal schedule (\(Int(drop.rounded()))% restored for \(window.shortLabel))."
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }
}
