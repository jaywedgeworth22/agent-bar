import AppKit
import QuotaCore
import SwiftUI

struct QuotaPopover: View {
    @ObservedObject var model: MonitorModel
    var openMonitor: () -> Void
    var openSettings: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AgentBar").font(.headline)
                    Text("\(model.reportingCount) platforms reporting").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Picker("Layout", selection: $model.viewLayout) {
                    ForEach(QuotaViewLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshing)
                .help("Refresh Quotas")
                .accessibilityLabel("Refresh Quotas")

                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }.padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    if model.isRefreshing { ProgressView("Refreshing quotas…").font(.caption).padding(4) }
                    if let error = model.serverError { Text(error).font(.caption).foregroundStyle(Palette.warning) }
                    if model.viewLayout == .summary {
                        ForEach(model.sections.sorted { !$0.windows.isEmpty && $1.windows.isEmpty }, id: \.providerKey) { section in
                            CompactPopoverPlatformRow(
                                section: section,
                                now: model.now,
                                issue: model.issues[section.providerKey],
                                customInfo: model.platformCustomInfo[section.providerKey]
                            )
                        }
                    } else {
                        ForEach(model.sections.sorted { !$0.windows.isEmpty && $1.windows.isEmpty }, id: \.providerKey) { section in
                            PlatformCard(
                                section: section,
                                now: model.now,
                                issue: model.issues[section.providerKey],
                                compact: true,
                                customInfo: model.platformCustomInfo[section.providerKey]
                            )
                        }
                    }
                }.padding(10)
            }.background(Palette.background)
            Divider()
            HStack {
                Button("Open Monitor", action: openMonitor).buttonStyle(.borderedProminent)
                Spacer()
                Menu {
                    Picker("Show In", selection: $model.displayMode) {
                        ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Picker("Menu Bar Style", selection: $model.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Menu Bar Quota", selection: $model.menuBarQuotaSelection) {
                        ForEach(model.availableMenuBarQuotas, id: \.id) { item in
                            Text(item.label).tag(item.id)
                        }
                    }
                    Divider()
                    Button("Quit AgentBar") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.ink)
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .frame(width: 28, height: 28)
            }.padding(12)
        }
        .frame(width: 410, height: 600)
        .tint(Palette.accent).preferredColorScheme(.light)
    }
}

struct CompactPopoverPlatformRow: View {
    let section: QuotaPlatformSection
    let now: Date
    let issue: String?
    var customInfo: PlatformCustomInfo? = nil

    private var primaryWindows: [QuotaWindowSnapshot] {
        section.windows.filter { !$0.window.isSupplementaryVideoQuota }
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
            return "Antigravity"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            PlatformLogo(providerKey: section.providerKey, size: 20)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(section.providerLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let sub = subtitleText {
                    Text(sub)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 88, alignment: .leading)

            Spacer(minLength: 2)

            if primaryWindows.isEmpty {
                Text(issue ?? "Unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(primaryWindows.prefix(3)), id: \.window.id) { snapshot in
                        CompactPopoverQuotaPill(snapshot: snapshot, now: now, sourceFailed: issue != nil)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.06)))
    }
}

struct CompactPopoverQuotaPill: View {
    let snapshot: QuotaWindowSnapshot
    let now: Date
    let sourceFailed: Bool

    private var color: Color {
        quotaStatusColor(for: snapshot, sourceFailed: sourceFailed)
    }

    private var resetCountdownText: String? {
        guard let reset = snapshot.resetAt else { return nil }
        let text = compactResetCountdown(reset, now: now)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 3) {
                Text(compactWindowName(snapshot.window.label))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(snapshot.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)

                if let resetText = resetCountdownText {
                    Text(resetText)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }

            if let pct = snapshot.remainingPercent {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.08))
                    Capsule().fill(color).frame(width: 44 * CGFloat(min(max(pct, 0), 100)) / 100)
                }
                .frame(width: 44, height: 3)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}
