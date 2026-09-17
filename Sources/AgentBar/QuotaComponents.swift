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

/// Two sentences in one UI string are separated by this, never by a bare space.
/// A no-break space plus a space survives every renderer AppKit hands it.
let sentenceGap = "\u{00A0} "

struct SummaryTile: View {
    let label: String
    let value: String
    let symbol: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(label, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }
}

struct PlatformCard: View {
    let section: QuotaPlatformSection
    let now: Date
    let issue: String?
    let compact: Bool
    var wide = false
    var customInfo: PlatformCustomInfo? = nil
    @State private var expanded = false
    @State private var videoExpanded = false

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
        if let custom = customInfo, !custom.customSubtitle.isEmpty {
            return custom.customSubtitle
        }
        if let custom = customInfo, custom.showCostAndRenewal {
            let parts = [custom.planName, custom.costUsd, custom.renewalDateText.isEmpty ? "" : "Renews \(custom.renewalDateText)"].filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        if section.via == "antigravity" {
            return "Antigravity subscription"
        }
        if let plan = section.windows.compactMap(\.window.planName).first, !plan.isEmpty {
            return plan
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(spacing: 10) {
                PlatformLogo(providerKey: section.providerKey, size: compact ? 25 : 32)
                    .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.providerLabel).font(.headline)
                    if let sub = subtitleText {
                        Text(sub).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !section.windows.isEmpty {
                    Text(issue == nil && section.hasFreshReport ? "LIVE" : "LAST REPORT")
                        .font(.system(size: 8, weight: .bold)).tracking(0.7)
                        .foregroundStyle(issue == nil && section.hasFreshReport ? Theme.accent : Theme.warning)
                }
            }
            if section.windows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Quota unavailable").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Text(issue ?? "No subscription quota source connected.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if wide && displayedWindows.count > 1 {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 22) {
                        ForEach(displayedWindows, id: \.window.id) { snapshot in
                            QuotaRow(snapshot: snapshot, now: now, sourceFailed: issue != nil, compact: compact)
                                .padding(12)
                                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                } else {
                    ForEach(Array(displayedWindows.enumerated()), id: \.offset) { index, snapshot in
                        if index > 0 { Divider() }
                        QuotaRow(snapshot: snapshot, now: now, sourceFailed: issue != nil, compact: compact)
                    }
                }
                if primaryWindows.count > 4 {
                    Button(expanded ? "Show Less" : "Show All \(primaryWindows.count) Windows") { expanded.toggle() }
                        .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                }
                if !videoWindows.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $videoExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(videoWindows, id: \.window.id) { snapshot in
                                QuotaRow(snapshot: snapshot, now: now, sourceFailed: issue != nil, compact: true)
                            }
                        }.padding(.top, 8)
                    } label: {
                        Label("Video · \(videoWindows.count) windows", systemImage: "video")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let issue {
                    Label(issue, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(compact ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }
}

struct QuotaRow: View {
    let snapshot: QuotaWindowSnapshot
    let now: Date
    let sourceFailed: Bool
    let compact: Bool
    private var tint: Color {
        if !snapshot.isFresh || sourceFailed || snapshot.remainingPercent == nil { return .secondary }
        if snapshot.status == .exhausted { return Theme.danger }
        if (snapshot.remainingPercent ?? 100) <= 20 { return Theme.warning }
        return Theme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.window.label).font(.system(size: compact ? 11 : 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(snapshot.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.system(size: compact ? 18 : 24, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(tint)
                    Text(snapshot.remainingPercent == nil ? "unavailable" : snapshot.isFresh && !sourceFailed ? "remaining" : "last reported")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }

            if let pacing = snapshot.pacing(now: now), !compact {
                // Timespan backdrop & usage bar comparison in Detailed view
                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let timeWidth = max(0, min(width, width * CGFloat(pacing.timeElapsedPercent) / 100))
                        let usedWidth = max(0, min(width, width * CGFloat(pacing.quotaUsedPercent) / 100))

                        ZStack(alignment: .leading) {
                            // Total window track
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.hairline)

                            // Time elapsed backdrop zone
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.pacingTrack.opacity(0.14))
                                .frame(width: timeWidth)

                            // Time progress pin
                            Rectangle()
                                .fill(Theme.pacingTrack.opacity(0.75))
                                .frame(width: 2, height: 10)
                                .offset(x: max(0, min(width - 2, timeWidth - 1)))

                            // Quota used fill bar
                            RoundedRectangle(cornerRadius: 3)
                                .fill(pacing.isUnderCapPace ? Theme.accent : Theme.warning)
                                .frame(width: usedWidth, height: 5)
                        }
                    }
                    .frame(height: 10)

                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Circle().fill(Theme.pacingTrack.opacity(0.8)).frame(width: 5, height: 5)
                            Text(pacing.timeElapsedLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 3) {
                            Image(systemName: pacing.isUnderCapPace ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(pacing.isUnderCapPace ? Theme.accent : Theme.warning)
                            Text(pacing.paceDescription)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(pacing.isUnderCapPace ? Theme.accent : Theme.warning)
                        }
                    }
                }
                .padding(.vertical, 2)
            } else if let remaining = snapshot.remainingPercent {
                // Standard single progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(tint).frame(width: geometry.size.width * remaining / 100)
                    }
                }.frame(height: 5)
                .accessibilityLabel("\(Int(remaining.rounded())) percent remaining")
            }

            if let remaining = snapshot.window.absoluteRemaining, let limit = snapshot.window.absoluteLimit,
               remaining.isFinite, limit.isFinite, remaining >= 0, limit > 0, let unit = snapshot.window.quotaUnit {
                Text("\(remaining.formatted(.number.precision(.fractionLength(0...1)))) of \(limit.formatted(.number.precision(.fractionLength(0...1)))) \(unit) remaining")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                Text(resetCountdown(snapshot.resetAt, now: now))
            }.font(.caption2).foregroundStyle(.secondary)

            if let reset = snapshot.resetAt, !compact {
                Text(reset.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute().timeZone()))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !compact {
                HStack {
                    Text(snapshot.observedAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Update time unavailable")
                    Spacer()
                    if snapshot.observedAt == nil { Text("Not reported") }
                    else if snapshot.isStale { Text("Stale").foregroundStyle(Theme.warning) }
                    else if let source = snapshot.window.source { Text(source).lineLimit(1) }
                }.font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }.accessibilityElement(children: .combine)
    }
}

func quotaStatusColor(for snapshot: QuotaWindowSnapshot, sourceFailed: Bool) -> Color {
    if !snapshot.isFresh || sourceFailed || snapshot.remainingPercent == nil { return .secondary }
    if snapshot.status == .exhausted { return Theme.danger }
    if (snapshot.remainingPercent ?? 100) <= 20 { return Theme.warning }
    return Theme.accent
}

func compactWindowName(_ label: String) -> String {
    let lower = label.lowercased()
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
    return label.components(separatedBy: " ").first ?? label
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
