import Foundation

/// Persistent user preferences for displaying providers and quota windows.
final class PreferencesStore: @unchecked Sendable {
    private static let hiddenProvidersKey = "Headroom.hiddenProviders"
    private static let hiddenShortLimitsKey = "Headroom.hiddenShortLimits"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isProviderHidden(_ provider: ProviderID) -> Bool {
        let list = defaults.stringArray(forKey: Self.hiddenProvidersKey) ?? []
        return list.contains(provider.rawValue)
    }

    func setProviderHidden(_ provider: ProviderID, hidden: Bool) {
        var list = defaults.stringArray(forKey: Self.hiddenProvidersKey) ?? []
        if hidden {
            if !list.contains(provider.rawValue) {
                list.append(provider.rawValue)
            }
        } else {
            list.removeAll { $0 == provider.rawValue }
        }
        defaults.set(list, forKey: Self.hiddenProvidersKey)
    }

    func isShortLimitHidden(for provider: ProviderID) -> Bool {
        let list = defaults.stringArray(forKey: Self.hiddenShortLimitsKey) ?? []
        return list.contains(provider.rawValue)
    }

    func setShortLimitHidden(for provider: ProviderID, hidden: Bool) {
        var list = defaults.stringArray(forKey: Self.hiddenShortLimitsKey) ?? []
        if hidden {
            if !list.contains(provider.rawValue) {
                list.append(provider.rawValue)
            }
        } else {
            list.removeAll { $0 == provider.rawValue }
        }
        defaults.set(list, forKey: Self.hiddenShortLimitsKey)
    }
}
