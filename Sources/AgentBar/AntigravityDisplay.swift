import Foundation
import QuotaCore

/// Antigravity sells two independent model pools.  QuotaCore exports them under
/// the names BotFleet and Usage Monitor already consume — `third-party`, and the
/// label `Third-Party Models` — so the rename the owner asked for lives here, in
/// the display layer, and never touches a wire string.
enum AntigravityDisplay {
    static let providerKey = "google-antigravity"

    /// The pool's name as a person reads it.
    static func poolTitle(_ poolKey: String) -> String {
        switch poolKey {
        case "gemini": return "Gemini"
        case "third-party": return "Claude & GPT"
        default: return poolKey
        }
    }

    /// The row title for one pool: "Antigravity · Claude & GPT".
    static func rowTitle(_ poolKey: String) -> String {
        "Antigravity · \(poolTitle(poolKey))"
    }

    /// The exported pool names, rewritten for display.  Any other label — a
    /// per-model window pulled from the fleet, for one — passes through.
    static func windowLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "Third-Party Models", with: poolTitle("third-party"))
            .replacingOccurrences(of: "Gemini Models", with: poolTitle("gemini"))
    }

    /// Whether a displayed label already names a pool, so a compact row can
    /// keep that name instead of shortening the label down to its cadence.
    static func poolName(in displayLabel: String) -> String? {
        guard let separator = displayLabel.range(of: " · ") else { return nil }
        let head = String(displayLabel[..<separator.lowerBound])
        return ["Gemini", "Claude & GPT"].contains(head) ? head : nil
    }

    /// The caption shown in place of a five-hour percentage that cannot mean
    /// anything, because the pool's weekly cap is already spent.
    static let maskedCaption = "not applicable while the weekly limit is exhausted"
    static let maskedValue = "n/a"
}

/// The window's name for a line that already names the platform or the pool:
/// "Antigravity · Gemini, weekly" rather than "Antigravity, Gemini · Weekly".
func windowCadenceName(_ window: QuotaWindow) -> String {
    let display = AntigravityDisplay.windowLabel(window.label)
    guard AntigravityDisplay.poolName(in: display) != nil,
          let separator = display.range(of: " · ") else { return display }
    return String(display[separator.upperBound...]).lowercased()
}

/// One row in Glance, in the Console sidebar and in the Console's card grid.
///
/// Every platform is one row except Antigravity, which is two: collapsing its
/// pools into a single number showed "Antigravity 0%" whenever the Claude/GPT
/// weekly cap was spent, while Gemini was still nearly full.
struct DisplaySection: Identifiable, Equatable {
    /// The selection key, unique per row: a provider key, or a pool-qualified
    /// one such as `google-antigravity:gemini`.
    let id: String
    /// The canonical provider, for the mark, the issue text and custom info.
    let providerKey: String
    let title: String
    /// The platform's own name, without the pool: "Antigravity".
    let platformTitle: String
    /// The section, scoped to this row's windows and titled for the row.
    let section: QuotaPlatformSection
    let poolKey: String?
    /// The row's headline percentage, with any masked window excluded.
    let remainingPercent: Double?
    /// The reset belonging to the window that set `remainingPercent`.
    let resetAt: Date?
    /// Windows whose reported percentage must not be believed.
    let maskedWindowIds: Set<String>

    var isPool: Bool { poolKey != nil }
    /// The pool's name on its own: "Gemini", "Claude & GPT".  A narrow row puts
    /// this on a second line rather than truncating the joined title.
    var poolTitle: String? { poolKey.map(AntigravityDisplay.poolTitle) }

    /// The window this row speaks for, used for freshness and attribution.
    var driving: QuotaWindowSnapshot? {
        let candidates = section.windows.filter { !$0.window.isSupplementaryVideoQuota }
        return candidates.first { $0.remainingPercent == remainingPercent && !maskedWindowIds.contains($0.window.id) }
            ?? candidates.filter { !maskedWindowIds.contains($0.window.id) }
                .min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
            ?? candidates.first
    }

    func isMasked(_ snapshot: QuotaWindowSnapshot) -> Bool {
        maskedWindowIds.contains(snapshot.window.id)
    }

    /// Splits one platform section into the rows the UI shows for it.
    static func rows(for section: QuotaPlatformSection, now: Date) -> [DisplaySection] {
        guard section.providerKey == AntigravityDisplay.providerKey else {
            return [plain(section)]
        }
        let pools = AntigravityQuotaGroups.pools(from: section.windows.map(\.window), now: now)
        guard !pools.isEmpty else { return [plain(section)] }
        return pools.map { pool in
            let ids = Set(pool.windows.map(\.id))
            let title = AntigravityDisplay.rowTitle(pool.key)
            let scoped = QuotaPlatformSection(
                providerKey: section.providerKey,
                providerLabel: title,
                via: section.via,
                expected: section.expected,
                windows: section.windows.filter { ids.contains($0.window.id) })
            // A pool whose windows are all stale still shows its last reading,
            // greyed, rather than dropping to a dash.
            let lastReported = scoped.windows
                .filter { !pool.maskedWindowIds.contains($0.window.id) && $0.remainingPercent != nil }
                .min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
            return DisplaySection(id: "\(section.providerKey):\(pool.key)",
                                  providerKey: section.providerKey,
                                  title: title,
                                  platformTitle: section.providerLabel,
                                  section: scoped,
                                  poolKey: pool.key,
                                  remainingPercent: pool.remainingPercent ?? lastReported?.remainingPercent,
                                  resetAt: pool.resetAt ?? lastReported?.resetAt,
                                  maskedWindowIds: pool.maskedWindowIds)
        }
    }

    private static func plain(_ section: QuotaPlatformSection) -> DisplaySection {
        let driving = section.drivingWindow
        return DisplaySection(id: section.providerKey,
                              providerKey: section.providerKey,
                              title: section.providerLabel,
                              platformTitle: section.providerLabel,
                              section: section,
                              poolKey: nil,
                              remainingPercent: section.minimumRemainingPercent ?? driving?.remainingPercent,
                              resetAt: driving?.resetAt,
                              maskedWindowIds: [])
    }
}
