import AppKit
import QuotaCore
import SwiftUI

enum Palette {
    static let ink = Color(red: 0.12, green: 0.17, blue: 0.23)
    static let accent = Color(red: 0.03, green: 0.45, blue: 0.43)
    static let background = Color(red: 0.96, green: 0.97, blue: 0.97)
    static let warning = Color(red: 0.66, green: 0.36, blue: 0.02)
    static let danger = Color(red: 0.75, green: 0.20, blue: 0.23)
    static let pacingTrack = Color(red: 0.15, green: 0.35, blue: 0.65)
}

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
        .padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.06)))
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
                        .foregroundStyle(issue == nil && section.hasFreshReport ? Palette.accent : Palette.warning)
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
                                .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
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
                        .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Palette.accent)
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
                        .font(.caption).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(compact ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.07)))
    }
}

struct QuotaRow: View {
    let snapshot: QuotaWindowSnapshot
    let now: Date
    let sourceFailed: Bool
    let compact: Bool
    private var tint: Color {
        if !snapshot.isFresh || sourceFailed || snapshot.remainingPercent == nil { return .secondary }
        if snapshot.status == .exhausted { return Palette.danger }
        if (snapshot.remainingPercent ?? 100) <= 20 { return Palette.warning }
        return Palette.accent
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
                                .fill(Color.black.opacity(0.06))

                            // Time elapsed backdrop zone
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Palette.pacingTrack.opacity(0.14))
                                .frame(width: timeWidth)

                            // Time progress pin
                            Rectangle()
                                .fill(Palette.pacingTrack.opacity(0.75))
                                .frame(width: 2, height: 10)
                                .offset(x: max(0, min(width - 2, timeWidth - 1)))

                            // Quota used fill bar
                            RoundedRectangle(cornerRadius: 3)
                                .fill(pacing.isUnderCapPace ? Palette.accent : Palette.warning)
                                .frame(width: usedWidth, height: 5)
                        }
                    }
                    .frame(height: 10)

                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Circle().fill(Palette.pacingTrack.opacity(0.8)).frame(width: 5, height: 5)
                            Text(pacing.timeElapsedLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 3) {
                            Image(systemName: pacing.isUnderCapPace ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(pacing.isUnderCapPace ? Palette.accent : Palette.warning)
                            Text(pacing.paceDescription)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(pacing.isUnderCapPace ? Palette.accent : Palette.warning)
                        }
                    }
                }
                .padding(.vertical, 2)
            } else if let remaining = snapshot.remainingPercent {
                // Standard single progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.06))
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
                    else if snapshot.isStale { Text("Stale").foregroundStyle(Palette.warning) }
                    else if let source = snapshot.window.source { Text(source).lineLimit(1) }
                }.font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }.accessibilityElement(children: .combine)
    }
}

func quotaStatusColor(for snapshot: QuotaWindowSnapshot, sourceFailed: Bool) -> Color {
    if !snapshot.isFresh || sourceFailed || snapshot.remainingPercent == nil { return .secondary }
    if snapshot.status == .exhausted { return Palette.danger }
    if (snapshot.remainingPercent ?? 100) <= 20 { return Palette.warning }
    return Palette.accent
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
