import AppKit
import QuotaCore
import SwiftUI

/// The whole colour vocabulary, in one place, with a dark value for every
/// token.  A dynamic `NSColor` resolves per appearance, so the SPM target needs
/// no asset catalog and nothing has to be re-rendered when the theme changes.
enum Theme {
    static let ink = dyn(hex(0x1F2B3A), hex(0xE8ECF1))
    static let accent = dyn(hex(0x087370), hex(0x4FD1C5))
    static let warning = dyn(hex(0xA85C05), hex(0xF0B45A))
    static let danger = dyn(hex(0xBF3339), hex(0xFF6B6B))
    static let background = dyn(hex(0xF5F7F7), hex(0x1C1E20))
    static let surface = dyn(hex(0xFFFFFF), hex(0x26292C))
    static let hairline = dyn(NSColor.black.withAlphaComponent(0.06),
                              NSColor.white.withAlphaComponent(0.10))
    static let pacingTrack = dyn(hex(0x2659A6), hex(0x7FA8E8))
    static let fleet = dyn(hex(0x4B4FA8), hex(0x8A8EE0))

    /// Unfilled portion of any progress bar.  A black 6% track disappears on a
    /// dark surface, so this is a token rather than a literal at each call site.
    static let track = dyn(NSColor.black.withAlphaComponent(0.08),
                           NSColor.white.withAlphaComponent(0.14))

    /// Fill behind a selected or highlighted row.
    static let selection = dyn(hex(0x087370).withAlphaComponent(0.12),
                               hex(0x4FD1C5).withAlphaComponent(0.18))

    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }
}

/// Every surface dimension the design fixes, declared once so the AppKit call
/// site and the SwiftUI root cannot disagree the way the old 580x510 window and
/// its 620x560 content did.
enum Metrics {
    static let glanceWidth: CGFloat = 360
    static let glanceMinHeight: CGFloat = 200
    static let glanceGutter: CGFloat = 12
    static let glanceHeaderHeight: CGFloat = 32
    static let glanceFooterHeight: CGFloat = 38
    static let glanceGroupHeaderHeight: CGFloat = 18
    static let glanceLocalRowHeight: CGFloat = 34
    static let glanceFleetRowHeight: CGFloat = 46
    static let glanceCTARowHeight: CGFloat = 52

    static let consoleDefault = NSSize(width: 960, height: 640)
    static let consoleMin = NSSize(width: 820, height: 560)
    static let sidebarWidth: CGFloat = 200
    static let toolbarHeight: CGFloat = 52
    static let pagePadding: CGFloat = 20

    static func glanceMaxHeight() -> CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 720) - 24
    }
}

// MARK: - Shared status rules

/// The 20% threshold lives here and nowhere else.
func quotaStatusColor(for snapshot: QuotaWindowSnapshot, sourceFailed: Bool) -> Color {
    if !snapshot.isFresh || sourceFailed || snapshot.remainingPercent == nil { return .secondary }
    if snapshot.status == .exhausted { return Theme.danger }
    if (snapshot.remainingPercent ?? 100) <= 20 { return Theme.warning }
    return Theme.accent
}

func compactWindowName(_ label: String) -> String {
    let display = AntigravityDisplay.windowLabel(label)
    // An Antigravity window says which pool it belongs to.  A compact row
    // shortens the cadence and keeps the pool, because "5h" alone is what made
    // two different pools look like one number.
    if let pool = AntigravityDisplay.poolName(in: display), let separator = display.range(of: " · ") {
        let cadence = String(display[separator.upperBound...])
        let shortCadence = cadence.lowercased().contains("5") ? "5h" : cadence
        return "\(pool) · \(shortCadence)"
    }
    let lower = display.lowercased()
    if lower.contains("5-hour") || lower.contains("5 hour") { return "5h" }
    if lower.contains("7-day") || lower.contains("7 day") { return "7d" }
    if lower.contains("weekly") { return "Weekly" }
    if lower.contains("daily") { return "Daily" }
    if lower.contains("fast request") { return "Fast" }
    if lower.contains("slow request") { return "Slow" }
    if lower.contains("session") { return "Session" }
    if lower.contains("claude 3.5") || lower.contains("sonnet") { return "Sonnet" }
    if lower.contains("gemini pro") || lower.contains("pro") { return "Pro" }
    if lower.contains("flash") { return "Flash" }
    if lower.contains("opus") { return "Opus" }
    return display.components(separatedBy: " ").first ?? display
}

func compactResetCountdown(_ reset: Date?, now: Date) -> String {
    guard let reset else { return "" }
    let seconds = reset.timeIntervalSince(now)
    guard seconds > 0 else { return "⟳" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 1440 { return "\(minutes / 1440)d" }
    if minutes >= 60 { return "\(minutes / 60)h" }
    return "\(minutes)m"
}

/// The one badge slot: `LIVE`, `LAST REPORT` or `FLEET`.  A pulled window is by
/// definition somebody else's observation, so it never claims to be live.
struct StatusBadge: View {
    enum Kind { case live, lastReport, fleet }
    let kind: Kind

    private var text: String {
        switch kind {
        case .live: return "LIVE"
        case .lastReport: return "LAST REPORT"
        case .fleet: return "FLEET"
        }
    }

    private var color: Color {
        switch kind {
        case .live: return Theme.accent
        case .lastReport: return Theme.warning
        case .fleet: return Theme.fleet
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}

/// The group eyebrow: `QUOTAS`, `THIS MAC`, `SHARE THIS MAC`, `DISPLAY`.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

extension QuotaPlatformSection {
    /// The single subtitle rule, replacing three near-identical copies that
    /// disagreed about the Antigravity fallback.
    func displaySubtitle(customInfo: PlatformCustomInfo?) -> String? {
        if let custom = customInfo, !custom.customSubtitle.isEmpty {
            return custom.customSubtitle
        }
        if let custom = customInfo, custom.showCostAndRenewal {
            let parts = [custom.planName,
                         custom.costUsd,
                         custom.renewalDateText.isEmpty ? "" : "Renews \(custom.renewalDateText)"]
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        if via == "antigravity" { return "Antigravity subscription" }
        if let plan = windows.compactMap(\.window.planName).first, !plan.isEmpty { return plan }
        return nil
    }

    /// The window a one-line row speaks for: whichever is closest to its cap.
    var drivingWindow: QuotaWindowSnapshot? {
        let primary = windows.filter { !$0.window.isSupplementaryVideoQuota }
        return primary.filter { $0.remainingPercent != nil }
            .min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
            ?? primary.first
    }

    /// The lowest remaining percentage across the windows a sidebar row summarises.
    var minimumRemainingPercent: Double? {
        windows.filter { $0.isFresh && !$0.window.isSupplementaryVideoQuota }
            .compactMap(\.remainingPercent)
            .min()
    }
}

/// Glance's height is computed from the EXPECTED provider count rather than the
/// reporting count, so the popover cannot resize under the pointer when a
/// platform appears or disappears between refreshes.
enum QuotaGlanceMetrics {
    @MainActor
    static func popoverHeight(for model: MonitorModel) -> CGFloat {
        guard model.localEnabled || model.serverEnabled else {
            return Metrics.glanceMinHeight
        }
        let fleetCount = model.originByProvider.values.filter { $0 == .fleet }.count
        let reported = Set(model.sections.map(\.providerKey))
        let expectedKeys = Set(expectedQuotaProviderKeys).union(reported)
        // Antigravity draws one row per model pool, so it counts twice.
        let expectedCount = expectedKeys.count
            + (expectedKeys.contains(AntigravityDisplay.providerKey) ? 1 : 0)
        let localRows = max(0, expectedCount - fleetCount)
        let groups = fleetCount > 0 ? 2 : 1
        let ctaRows = (!model.syncEnabled && !model.serverEnabled) ? 1 : 0

        let content = CGFloat(groups) * Metrics.glanceGroupHeaderHeight
            + CGFloat(localRows) * Metrics.glanceLocalRowHeight
            + CGFloat(fleetCount) * Metrics.glanceFleetRowHeight
            + CGFloat(ctaRows) * (Metrics.glanceCTARowHeight + 26)
            + (fleetCount > 0 ? 12 : 0)
        let total = Metrics.glanceHeaderHeight + Metrics.glanceFooterHeight + 18 + content
        return min(Metrics.glanceMaxHeight(), max(Metrics.glanceMinHeight, total))
    }
}

// MARK: - Console detail components

struct SummaryTile: View {
    let label: String
    let value: String
    let symbol: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
    }
}

/// A bordered container with a header and one or more `QuotaRow`s.  Cards exist
/// only in the Console detail pane; rows exist only in Glance and the sidebar.
struct PlatformCard: View {
    let row: DisplaySection
    let now: Date
    let issue: String?
    let compact: Bool
    var wide = false
    var origin: QuotaOrigin = .local
    var customInfo: PlatformCustomInfo? = nil
    @State private var expanded = false
    @State private var videoExpanded = false

    private var section: QuotaPlatformSection { row.section }

    private var primaryWindows: [QuotaWindowSnapshot] {
        section.windows.filter { !$0.window.isSupplementaryVideoQuota }
    }
    private var videoWindows: [QuotaWindowSnapshot] {
        section.windows.filter { $0.window.isSupplementaryVideoQuota }
    }
    private var displayedWindows: [QuotaWindowSnapshot] {
        expanded ? primaryWindows : Array(primaryWindows.prefix(4))
    }
    private var subtitleText: String? {
        if origin == .fleet {
            return section.drivingWindow?.window.source
        }
        return section.displaySubtitle(customInfo: customInfo)
    }
    private var badge: StatusBadge.Kind {
        if origin == .fleet { return .fleet }
        return issue == nil && section.hasFreshReport ? .live : .lastReport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            header
            if section.windows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quota unavailable")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(issue ?? "no quota source connected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                windowsBody
            }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        .opacity(issue == nil ? 1 : 0.72)
    }

    private var header: some View {
        HStack(spacing: 10) {
            PlatformLogo(providerKey: section.providerKey, size: compact ? 22 : 28)
                .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.providerLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let subtitleText {
                    Text(subtitleText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if !section.windows.isEmpty { StatusBadge(kind: badge) }
        }
    }

    @ViewBuilder
    private var windowsBody: some View {
        if wide && displayedWindows.count > 1 {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 16) {
                ForEach(displayedWindows, id: \.window.id) { snapshot in
                    QuotaRow(snapshot: snapshot, now: now, sourceFailed: issue != nil, compact: compact,
                             masked: row.isMasked(snapshot))
                        .padding(12)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } else {
            ForEach(Array(displayedWindows.enumerated()), id: \.offset) { index, snapshot in
                if index > 0 { Divider() }
                QuotaRow(snapshot: snapshot, now: now, sourceFailed: issue != nil, compact: compact,
                         masked: row.isMasked(snapshot))
            }
        }
        if primaryWindows.count > 4 {
            Button(expanded ? "Show Less" : "Show All \(primaryWindows.count) Windows") {
                expanded.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
        if !videoWindows.isEmpty {
            Divider()
            DisclosureGroup(isExpanded: $videoExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(videoWindows, id: \.window.id) { snapshot in
                        QuotaRow(snapshot: snapshot, now: now, sourceFailed: issue != nil, compact: true)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Video · \(videoWindows.count) Windows", systemImage: "video")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        if let issue {
            Label(issue, systemImage: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct QuotaRow: View {
    let snapshot: QuotaWindowSnapshot
    let now: Date
    let sourceFailed: Bool
    let compact: Bool
    /// True for a five-hour Antigravity window whose pool's weekly cap is spent.
    /// Its percentage is real and meaningless, so it is never shown as a number.
    var masked = false

    private var tint: Color {
        masked ? .secondary : quotaStatusColor(for: snapshot, sourceFailed: sourceFailed)
    }
    private var percentText: String {
        if masked { return AntigravityDisplay.maskedValue }
        return snapshot.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
    }
    private var stateText: String {
        if masked { return "not applicable" }
        if snapshot.remainingPercent == nil { return "unavailable" }
        return snapshot.isFresh && !sourceFailed ? "remaining" : "last reported"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(compact ? compactWindowName(snapshot.window.label)
                             : AntigravityDisplay.windowLabel(snapshot.window.label))
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(percentText)
                        .font(.system(size: compact ? 18 : 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                    Text(stateText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if masked {
                Text(AntigravityDisplay.maskedCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let pacing = snapshot.pacing(now: now), !compact {
                pacingBar(pacing)
            } else if let remaining = snapshot.remainingPercent {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(tint)
                            .frame(width: geometry.size.width * CGFloat(min(max(remaining, 0), 100)) / 100)
                    }
                }
                .frame(height: 5)
                .accessibilityLabel("Quota Remaining")
                .accessibilityValue("\(Int(remaining.rounded())) percent remaining")
            }

            if let remaining = snapshot.window.absoluteRemaining,
               let limit = snapshot.window.absoluteLimit,
               remaining.isFinite, limit.isFinite, remaining >= 0, limit > 0,
               let unit = snapshot.window.quotaUnit {
                Text("\(remaining.formatted(.number.precision(.fractionLength(0...1)))) of \(limit.formatted(.number.precision(.fractionLength(0...1)))) \(unit) left")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                Text(resetCountdown(snapshot.resetAt, now: now))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if let reset = snapshot.resetAt, !compact {
                Text(reset.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !compact {
                HStack {
                    Text(snapshot.observedAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" }
                         ?? "update time unavailable")
                    Spacer()
                    if snapshot.observedAt == nil { Text("not reported") }
                    else if snapshot.isStale { Text("stale").foregroundStyle(Theme.warning) }
                    else if let source = snapshot.window.source { Text(source).lineLimit(1) }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func pacingBar(_ pacing: WindowPacing) -> some View {
        let paceLabel = pacing.isUnderCapPace ? "Under cap pace" : "Over cap pace"
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let timeWidth = max(0, min(width, width * CGFloat(pacing.timeElapsedPercent) / 100))
                let usedWidth = max(0, min(width, width * CGFloat(pacing.quotaUsedPercent) / 100))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.track)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.pacingTrack.opacity(0.14))
                        .frame(width: timeWidth)
                    Rectangle()
                        .fill(Theme.pacingTrack.opacity(0.75))
                        .frame(width: 2, height: 10)
                        .offset(x: max(0, min(width - 2, timeWidth - 1)))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(pacing.isUnderCapPace ? Theme.accent : Theme.warning)
                        .frame(width: usedWidth, height: 5)
                }
            }
            .frame(height: 10)
            .accessibilityLabel("Quota Pacing")
            .accessibilityValue("\(Int((snapshot.remainingPercent ?? 0).rounded())) percent remaining, \(pacing.timeElapsedLabel.lowercased()), \(paceLabel.lowercased())")

            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Circle().fill(Theme.pacingTrack.opacity(0.8)).frame(width: 5, height: 5)
                    Text("time elapsed · \(pacing.timeElapsedLabel.lowercased())")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Image(systemName: pacing.isUnderCapPace ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(paceLabel)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(pacing.isUnderCapPace ? Theme.accent : Theme.warning)
            }
        }
        .padding(.vertical, 2)
    }
}
