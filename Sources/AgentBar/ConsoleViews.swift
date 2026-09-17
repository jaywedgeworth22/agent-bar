import AppKit
import QuotaCore
import SwiftUI

struct MonitorDashboard: View {
    @ObservedObject var model: MonitorModel
    var openSettings: () -> Void
    @State private var selected = "all"
    @State private var query = ""

    private var visibleSections: [QuotaPlatformSection] {
        model.sections.filter { section in
            (selected == "all" || selected == section.providerKey)
                && (query.isEmpty || section.providerLabel.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        summary
                        if let error = model.serverError {
                            Label("Server: \(error)  Local readings remain available.", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(Theme.warning)
                        }
                        if let error = model.handoffError {
                            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
                        }
                        if !model.localEnabled && !model.serverEnabled {
                            ContentUnavailableView("Connect a Quota Source", systemImage: "link",
                                                   description: Text("Enable local agent readings or connect your Usage Monitor server in Settings."))
                        }
                        HStack {
                            Text(selected == "all" ? "Subscription Quotas" : visibleSections.first?.providerLabel ?? "Subscription Quotas")
                                .font(.title3.bold())
                            Spacer()
                            Text("Percent remaining").font(.caption).foregroundStyle(.secondary)
                        }
                        if model.viewLayout == .summary && selected == "all" {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .top)], alignment: .leading, spacing: 12) {
                                ForEach(visibleSections, id: \.providerKey) { section in
                                    CompactDashboardPlatformCard(
                                        section: section,
                                        now: model.now,
                                        issue: model.issues[section.providerKey],
                                        customInfo: model.platformCustomInfo[section.providerKey]
                                    )
                                }
                            }
                        } else {
                            LazyVGrid(columns: selected == "all" ? [GridItem(.adaptive(minimum: 290), alignment: .top)] : [GridItem(.flexible())], alignment: .leading, spacing: 16) {
                                ForEach(visibleSections, id: \.providerKey) { section in
                                    PlatformCard(
                                        section: section,
                                        now: model.now,
                                        issue: model.issues[section.providerKey],
                                        compact: false,
                                        wide: selected != "all",
                                        customInfo: model.platformCustomInfo[section.providerKey]
                                    )
                                }
                            }
                        }
                        Text("Each window is an independent cap. A model offered through Antigravity uses the Antigravity subscription. Unreported limits stay unavailable.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(26)
                }
                .background(Theme.background)
                .id(selected + query)
            }
        }
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "gauge.with.dots.needle.50percent").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AgentBar").font(.headline)
                    Text("AGENT SUBSCRIPTIONS").font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(1.1).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 24)
            List(selection: $selected) {
                Label("All Platforms", systemImage: "square.grid.2x2").tag("all")
                Section("Platforms") {
                    ForEach(model.sections, id: \.providerKey) { section in
                        HStack(spacing: 8) {
                            PlatformLogo(providerKey: section.providerKey, size: 17)
                            Text(section.providerLabel)
                            Spacer()
                            if section.providerKey != "google-antigravity", model.issues[section.providerKey] == nil, let remaining = section.windows.filter({ $0.isFresh && !$0.window.isSupplementaryVideoQuota }).compactMap(\.remainingPercent).min() {
                                Text("\(Int(remaining.rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }.tag(section.providerKey)
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            VStack(alignment: .leading, spacing: 10) {
                Label(model.localEnabled ? "Local Mac readings" : "Local readings off", systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.open(URL(string: "https://usage.jays.services")!)
                } label: { Label("Web Dashboard", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.plain).font(.caption)
                Button(action: openSettings) { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.plain)
            }.padding(18)
        }
        .frame(width: 208)
        .background(Theme.surface)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent Quotas").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Your subscriptions, at a glance.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Layout", selection: $model.viewLayout) {
                ForEach(QuotaViewLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            TextField("Find a platform", text: $query).textFieldStyle(.roundedBorder).frame(width: 145)
                .accessibilityLabel("Find a platform")
            Button { model.refresh() } label: {
                Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }.disabled(model.isRefreshing)
        }.padding(22).background(Theme.surface)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            SummaryTile(label: "Reporting", value: "\(model.reportingCount) / \(model.sections.count)", symbol: "antenna.radiowaves.left.and.right", detail: "Platforms with current readings")
            SummaryTile(label: "Near Cap", value: "\(model.nearCapCount)", symbol: "gauge.with.dots.needle.100percent", detail: "Windows at 20% or less")
            SummaryTile(label: "Next Reset", value: model.nextReset.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—", symbol: "clock", detail: model.nextReset.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "No current reset reported")
        }
    }
}

struct CompactDashboardPlatformCard: View {
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
            return "Antigravity subscription"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PlatformLogo(providerKey: section.providerKey, size: 22)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.providerLabel)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    if let sub = subtitleText {
                        Text(sub).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !section.windows.isEmpty {
                    Text(issue == nil && section.hasFreshReport ? "LIVE" : "LAST REPORT")
                        .font(.system(size: 8, weight: .bold)).tracking(0.6)
                        .foregroundStyle(issue == nil && section.hasFreshReport ? Theme.accent : Theme.warning)
                }
            }

            if primaryWindows.isEmpty {
                Text(issue ?? "Quota unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(primaryWindows.prefix(3)), id: \.window.id) { snapshot in
                        CompactDashboardQuotaRow(snapshot: snapshot, now: now, sourceFailed: issue != nil)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }
}

struct CompactDashboardQuotaRow: View {
    let snapshot: QuotaWindowSnapshot
    let now: Date
    let sourceFailed: Bool

    private var color: Color {
        quotaStatusColor(for: snapshot, sourceFailed: sourceFailed)
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.window.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(snapshot.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            if let pct = snapshot.remainingPercent {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(max(pct, 0), 100)) / 100)
                    }
                }
                .frame(height: 3)
            }
            HStack {
                if let reset = snapshot.resetAt {
                    Text(resetCountdown(reset, now: now))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let remaining = snapshot.window.absoluteRemaining, let limit = snapshot.window.absoluteLimit,
                   remaining.isFinite, limit.isFinite, remaining >= 0, limit > 0, let unit = snapshot.window.quotaUnit {
                    Text("\(remaining.formatted(.number.precision(.fractionLength(0...1)))) / \(limit.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
