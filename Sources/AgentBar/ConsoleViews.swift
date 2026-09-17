import AppKit
import QuotaCore
import SwiftUI

/// One selection type for the sidebar, the detail pane and every deep link from
/// Glance, the app menu and the status menu.
enum ConsolePage: Hashable {
    case allPlatforms
    case platform(String)
    case settingsMenuBar
    case settingsPlatforms
    case settingsSourcesFleet
    case settingsAppearance
    case settingsAbout

    var isSettings: Bool {
        switch self {
        case .allPlatforms, .platform: return false
        default: return true
        }
    }

    var storageKey: String {
        switch self {
        case .allPlatforms: return "allPlatforms"
        case .platform(let providerKey): return "platform:" + providerKey
        case .settingsMenuBar: return "settingsMenuBar"
        case .settingsPlatforms: return "settingsPlatforms"
        case .settingsSourcesFleet: return "settingsSourcesFleet"
        case .settingsAppearance: return "settingsAppearance"
        case .settingsAbout: return "settingsAbout"
        }
    }

    static func fromStorageKey(_ value: String) -> ConsolePage? {
        switch value {
        case "allPlatforms": return .allPlatforms
        case "settingsMenuBar": return .settingsMenuBar
        case "settingsPlatforms": return .settingsPlatforms
        case "settingsSourcesFleet": return .settingsSourcesFleet
        case "settingsAppearance": return .settingsAppearance
        case "settingsAbout": return .settingsAbout
        default:
            guard value.hasPrefix("platform:") else { return nil }
            return .platform(String(value.dropFirst(9)))
        }
    }

    /// Sidebar and toolbar label.  A platform page is titled by the model.
    var settingsTitle: String {
        switch self {
        case .settingsMenuBar: return "Menu Bar"
        case .settingsPlatforms: return "Platforms"
        case .settingsSourcesFleet: return "Sources & Fleet"
        case .settingsAppearance: return "Appearance"
        case .settingsAbout: return "About"
        default: return "AgentBar"
        }
    }

    var symbol: String {
        switch self {
        case .settingsMenuBar: return "menubar.rectangle"
        case .settingsPlatforms: return "square.grid.2x2"
        case .settingsSourcesFleet: return "arrow.up.arrow.down.circle"
        case .settingsAppearance: return "circle.lefthalf.filled"
        case .settingsAbout: return "info.circle"
        default: return "square.grid.2x2"
        }
    }

    static let settingsPages: [ConsolePage] = [
        .settingsMenuBar, .settingsPlatforms, .settingsSourcesFleet, .settingsAppearance, .settingsAbout,
    ]
}

/// Selection state shared between AppKit (which owns the window and its title)
/// and SwiftUI (which owns the sidebar and detail pane).
@MainActor
final class ConsoleState: ObservableObject {
    @Published var page: ConsolePage = .allPlatforms {
        didSet {
            guard page != oldValue else { return }
            if page.isSettings {
                defaults.set(page.storageKey, forKey: "consoleLastSettingsPage")
            }
            defaults.set(page.storageKey, forKey: "consoleLastPage")
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A Settings page is a destination, never a place to resume.
        let stored = defaults.string(forKey: "consoleLastPage").flatMap(ConsolePage.fromStorageKey)
        page = (stored?.isSettings == false ? stored : nil) ?? .allPlatforms
    }

    var lastSettingsPage: ConsolePage {
        defaults.string(forKey: "consoleLastSettingsPage")
            .flatMap(ConsolePage.fromStorageKey)
            .flatMap { $0.isSettings ? $0 : nil }
            ?? .settingsMenuBar
    }
}

/// The one window.  Deliberately a plain `HStack` rather than a
/// `NavigationSplitView`: the sidebar is a two-section flat list that needs
/// neither a collapse toggle nor animated column resizing, and a fixed 200pt
/// column is exactly what the design asks for.
struct ConsoleView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ConsoleSidebar(model: model, state: state)
                .frame(width: Metrics.sidebarWidth)
            Divider()
            detail
        }
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .background(Theme.background)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if model.isRefreshing {
                Rectangle().fill(Theme.accent).frame(height: 2)
                    .accessibilityHidden(true)
            }
            ScrollView {
                switch state.page {
                case .allPlatforms:
                    AllPlatformsPage(model: model, state: state, query: query)
                        .padding(Metrics.pagePadding)
                case .platform(let key):
                    PlatformDetailPage(model: model, providerKey: key)
                        .padding(Metrics.pagePadding)
                case .settingsMenuBar:
                    SettingsMenuBarPage(model: model)
                case .settingsPlatforms:
                    SettingsPlatformsPage(model: model)
                case .settingsSourcesFleet:
                    SettingsSourcesFleetPage(model: model)
                case .settingsAppearance:
                    SettingsAppearancePage(model: model)
                case .settingsAbout:
                    SettingsAboutPage(model: model, state: state)
                }
            }
            .background(Theme.background)
        }
    }

    private var pageTitle: String {
        switch state.page {
        case .allPlatforms: return "All Platforms"
        case .platform(let key):
            return model.sections.first { $0.providerKey == key }?.providerLabel ?? key
        default: return state.page.settingsTitle
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(pageTitle)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 8)
            if !state.page.isSettings {
                Picker("Layout", selection: $model.viewLayout) {
                    ForEach(QuotaViewLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
                .help("Quota Layout")
                .accessibilityLabel("Quota Layout")

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Find a Platform", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand { query = "" }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                .frame(width: 180)
                .help("Find a Platform")
                .accessibilityLabel("Find a Platform")
            }

            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
            }
            .disabled(model.isRefreshing)
            .help("Refresh Quotas")
            .accessibilityLabel("Refresh Quotas")

            Toggle(isOn: $model.keepConsoleInFront) {
                Image(systemName: "pin").frame(width: 18, height: 18)
            }
            .toggleStyle(.button)
            .help("Keep In Front")
            .accessibilityLabel("Keep In Front")
        }
        .padding(.horizontal, Metrics.pagePadding)
        .frame(height: Metrics.toolbarHeight)
        .background(Theme.surface)
    }
}

// MARK: - Sidebar

struct ConsoleSidebar: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { state.page }, set: { state.page = $0 ?? .allPlatforms })) {
                Section {
                    Label("All Platforms", systemImage: "square.grid.2x2")
                        .tag(ConsolePage.allPlatforms)
                    ForEach(model.sections, id: \.providerKey) { section in
                        quotaRow(section).tag(ConsolePage.platform(section.providerKey))
                    }
                } header: {
                    Eyebrow("QUOTAS")
                }
                Section {
                    ForEach(ConsolePage.settingsPages, id: \.self) { page in
                        Label(page.settingsTitle, systemImage: page.symbol).tag(page)
                    }
                } header: {
                    Eyebrow("SETTINGS")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            footer
        }
        .background(Theme.surface)
    }

    /// Quotas rows carry a trailing value; Settings rows do not.  Two different
    /// row views is what stops `.listStyle(.sidebar)` aligning them identically.
    private func quotaRow(_ section: QuotaPlatformSection) -> some View {
        HStack(spacing: 8) {
            PlatformLogo(providerKey: section.providerKey, size: 16)
            Text(section.providerLabel)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.issues[section.providerKey] != nil {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .accessibilityLabel("Quota unavailable")
            } else if let remaining = section.minimumRemainingPercent {
                Text("\(Int(remaining.rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if model.lastChecked == nil {
                Capsule().fill(Theme.track).frame(width: 28, height: 10)
                    .accessibilityHidden(true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.localEnabled ? "Local readings on" : "Local readings off",
                  systemImage: "desktopcomputer")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Local Quota Readers Status")
                .accessibilityLabel("Local Quota Readers Status")
            if let handoffError = model.handoffError {
                Text(handoffError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(AgentBarVersion.display)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

// MARK: - All Platforms

struct AllPlatformsPage: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState
    let query: String

    private var matching: [QuotaPlatformSection] {
        model.sections.filter {
            query.isEmpty || $0.providerLabel.localizedCaseInsensitiveContains(query)
        }
    }
    private var localSections: [QuotaPlatformSection] {
        matching.filter { model.originByProvider[$0.providerKey] != .fleet }
    }
    private var fleetSections: [QuotaPlatformSection] {
        matching.filter { model.originByProvider[$0.providerKey] == .fleet }
    }
    private var compact: Bool { model.viewLayout == .summary }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: compact ? 240 : 290), alignment: .top)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            tiles
            if let error = model.serverError { errorBanner(error) }

            if !model.localEnabled && !model.serverEnabled {
                emptyState
            } else {
                HStack {
                    Text("This Mac").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Percent remaining").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(localSections, id: \.providerKey) { section in
                        card(section, origin: .local)
                    }
                }
                if model.serverEnabled { fleetGroup }
            }

            Text("Quota windows are independent." + sentenceGap
                 + "Antigravity reports a single subscription across its models.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .top)], spacing: 12) {
            SummaryTile(label: "Reporting",
                        value: model.lastChecked == nil ? "—" : "\(model.reportingCount) of \(model.sections.count)",
                        symbol: "antenna.radiowaves.left.and.right",
                        detail: "reporting")
            SummaryTile(label: "Near Cap",
                        value: model.lastChecked == nil ? "—" : "\(model.nearCapCount)",
                        symbol: "gauge.with.dots.needle.100percent",
                        detail: "at 20% or less")
            SummaryTile(label: "Next Reset",
                        value: model.nextReset.map { glanceResetCountdown($0, now: model.now) } ?? "—",
                        symbol: "clock",
                        detail: model.nextReset.map { $0.formatted(date: .omitted, time: .shortened) } ?? "no reset reported")
            SummaryTile(label: "Fleet",
                        value: model.serverEnabled ? "\(model.fleetWindowCount) windows" : "Off",
                        symbol: "arrow.up.arrow.down.circle",
                        detail: model.serverEnabled
                            ? (model.lastPullTime.map { "pulled \($0.formatted(date: .omitted, time: .shortened))" } ?? "never pulled")
                            : "set up fleet pull")
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fleet refresh failed." + sentenceGap + "Showing the last report.")
                    .font(.system(size: 12, weight: .medium))
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings") { state.page = .settingsSourcesFleet }
                .help("Open Settings")
                .accessibilityLabel("Open Settings")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.warning.opacity(0.35)))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Connect a Quota Source", systemImage: "link")
        } description: {
            Text("AgentBar reads quota from the agent CLIs already signed in on this Mac."
                 + sentenceGap + "You can also pull quota from your other machines.")
        } actions: {
            HStack(spacing: 10) {
                Button("Turn On Local Readers") {
                    model.setLocalEnabled(true)
                    state.page = .settingsSourcesFleet
                }
                .buttonStyle(.borderedProminent)
                Button("Set Up Fleet Pull") { state.page = .settingsSourcesFleet }
            }
        }
    }

    @ViewBuilder
    private var fleetGroup: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(Theme.fleet).frame(width: 2)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(fleetTitle).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(model.lastPullTime.map { "Pulled \($0.formatted(date: .omitted, time: .shortened))" } ?? "Never pulled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if fleetSections.isEmpty {
                    Text("No other machines have reported yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(fleetSections, id: \.providerKey) { section in
                            card(section, origin: .fleet)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fleetTitle: String {
        let labels = model.fleetSourceLabels
        return labels.isEmpty ? "Fleet" : "Fleet · \(labels.joined(separator: ", "))"
    }

    private func card(_ section: QuotaPlatformSection, origin: QuotaOrigin) -> some View {
        PlatformCard(section: section,
                     now: model.now,
                     issue: model.issues[section.providerKey],
                     compact: compact,
                     wide: false,
                     origin: origin,
                     customInfo: model.platformCustomInfo[section.providerKey])
    }
}

// MARK: - Single platform

struct PlatformDetailPage: View {
    @ObservedObject var model: MonitorModel
    let providerKey: String

    @State private var customSubtitle = ""
    @State private var planName = ""
    @State private var costUsd = ""
    @State private var renewalDate = ""
    @State private var showCostAndRenewal = false

    private var section: QuotaPlatformSection? {
        model.sections.first { $0.providerKey == providerKey }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let section {
                PlatformCard(section: section,
                             now: model.now,
                             issue: model.issues[providerKey],
                             compact: false,
                             wide: true,
                             origin: model.originByProvider[providerKey] ?? .local,
                             customInfo: model.platformCustomInfo[providerKey])
            } else {
                Text("Quota unavailable")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            displaySection
        }
        .onAppear(perform: load)
        .onDisappear(perform: save)
        .onChange(of: providerKey) { _, _ in load() }
    }

    /// Editing a platform's presentation happens on that platform's own page,
    /// which is why Settings ▸ Platforms needs no row selection and no flush.
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("DISPLAY")
            VStack(alignment: .leading, spacing: 12) {
                field("Custom Subtitle", "e.g. Pro tier, Custom text, etc.", $customSubtitle,
                      caption: "Replaces the default subtitle.")
                Divider()
                Toggle("Display Plan, Cost and Renewal", isOn: $showCostAndRenewal)
                    .onChange(of: showCostAndRenewal) { _, _ in save() }
                field("Plan Name", "e.g. Max 20x, Pro", $planName, disabled: !showCostAndRenewal)
                field("Cost", "e.g. $20/mo", $costUsd, disabled: !showCostAndRenewal)
                field("Renewal Date", "e.g. Oct 12 or Monthly", $renewalDate, disabled: !showCostAndRenewal)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    private func field(_ label: String, _ placeholder: String, _ binding: Binding<String>,
                       caption: String? = nil, disabled: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                TextField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(disabled)
                    .onSubmit(save)
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() {
        let existing = model.platformCustomInfo[providerKey] ?? PlatformCustomInfo()
        customSubtitle = existing.customSubtitle
        planName = existing.planName
        costUsd = existing.costUsd
        renewalDate = existing.renewalDateText
        showCostAndRenewal = existing.showCostAndRenewal
    }

    private func save() {
        model.setCustomInfo(for: providerKey,
                            info: PlatformCustomInfo(customSubtitle: customSubtitle,
                                                     planName: planName,
                                                     costUsd: costUsd,
                                                     renewalDateText: renewalDate,
                                                     showCostAndRenewal: showCostAndRenewal))
    }
}

/// Version string, read once from the bundle the build script writes.
enum AgentBarVersion {
    static let display: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }()
}
