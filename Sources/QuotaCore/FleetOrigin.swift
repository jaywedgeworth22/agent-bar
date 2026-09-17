import Foundation

/// Where a pulled quota window came from.
///
/// The quota endpoint carries no host, producer or device field — a live
/// response has `source` and `sourceApp` and nothing else — so those are the
/// best machine identifier available, and inventing a richer one would mean
/// inventing the data behind it.  This is the single place to teach if the
/// payload ever grows a machine field.
public enum FleetOrigin {
    /// The origin a window names, or `fleet` when it names none.
    public static func identity(of window: QuotaWindow) -> String {
        for candidate in [window.source, window.sourceApp] {
            let value = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return "fleet"
    }

    /// Whether a pulled window is this Mac's own push coming back.  Such a
    /// window belongs under This Mac and must never be duplicated under Fleet.
    public static func isOwnPush(_ window: QuotaWindow, host: String = QuotaPublisher.producerInstanceId) -> Bool {
        let identity = identity(of: window).lowercased()
        let mine = [QuotaPublisher.producerId.lowercased(),
                    host.lowercased(),
                    host.lowercased().replacingOccurrences(of: ".local", with: "")]
        return mine.contains(identity)
    }

    /// "antigravity-usage" reads as "Antigravity Usage" in a group header.
    public static func title(for identity: String) -> String {
        identity
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Splits pulled windows into this Mac's own push and everybody else's,
    /// with the second group keyed by origin and sorted for a stable header
    /// order.
    public static func split(
        _ windows: [QuotaWindow],
        host: String = QuotaPublisher.producerInstanceId
    ) -> (ownPush: [QuotaWindow], groups: [(id: String, title: String, windows: [QuotaWindow])]) {
        var own: [QuotaWindow] = []
        var grouped: [String: [QuotaWindow]] = [:]
        for window in windows {
            if isOwnPush(window, host: host) {
                own.append(window)
            } else {
                grouped[identity(of: window), default: []].append(window)
            }
        }
        let groups = grouped.keys.sorted().map { (id: $0, title: title(for: $0), windows: grouped[$0] ?? []) }
        return (own, groups)
    }
}
