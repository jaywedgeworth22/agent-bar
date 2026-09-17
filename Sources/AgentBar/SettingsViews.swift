import AppKit
import QuotaCore
import SwiftUI

/// Shared chrome for a settings page.  Every page is a `Form` with no fixed
/// height, inside the Console's own `ScrollView`, so the 580x510-versus-620x560
/// clipping bug cannot recur anywhere.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .padding(.vertical, 4)
    }
}

// MARK: - Menu Bar

struct SettingsMenuBarPage: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        SettingsPage {
            Section {
                Picker("Show In", selection: $model.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Both keeps the menu bar icon and a Dock icon." + sentenceGap
                     + "Dock hides the menu bar icon, so use Open AgentBar to reach your quota.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Style", selection: $model.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Displayed Quota", selection: $model.menuBarQuotaSelection) {
                    ForEach(model.availableMenuBarQuotas, id: \.id) { item in
                        Text(item.label).tag(item.id)
                    }
                }
            } header: {
                Eyebrow("MENU BAR")
            }

            Section {
                LabeledContent("Preview") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            if model.menuBarStyle != .percentOnly {
                                PlatformLogo(providerKey: model.menuBarTargetSnapshot?.window.canonicalProviderKey ?? "auto",
                                             size: 14)
                            }
                            if model.menuBarStyle != .symbolOnly {
                                Text(model.menuBarTitle.isEmpty ? "—" : model.menuBarTitle)
                                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                            }
                        }
                        Text(model.menuBarDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Menu Bar Preview")
                }
            }
        }
    }
}

// MARK: - Platforms

struct SettingsPlatformsPage: View {
    @ObservedObject var model: MonitorModel
    @State private var selection: String?

    private var orderedKeys: [String] {
        let live = model.sections.map(\.providerKey)
        guard !model.platformOrder.isEmpty else { return live }
        let ordered = model.platformOrder.filter(live.contains)
        return ordered + live.filter { !ordered.contains($0) }
    }

    private func label(for providerKey: String) -> String {
        model.sections.first { $0.providerKey == providerKey }?.providerLabel ?? providerKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag to reorder." + sentenceGap
                 + "This order is used in the quota list and in Glance.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // A plain List outside a Form group, because `.onMove`'s drop
            // indicator misbehaves inside `.formStyle(.grouped)`.
            List(selection: $selection) {
                ForEach(orderedKeys, id: \.self) { providerKey in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .help("Drag to Reorder")
                            .accessibilityHidden(true)
                        PlatformLogo(providerKey: providerKey, size: 16)
                        Text(label(for: providerKey)).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .tag(providerKey)
                    .accessibilityLabel("\(label(for: providerKey)), position \((orderedKeys.firstIndex(of: providerKey) ?? 0) + 1) of \(orderedKeys.count)")
                }
                .onMove(perform: move)
            }
            .listStyle(.inset)
            // One expression, because a `minHeight` of 240 above a `maxHeight`
            // of 226 (seven platforms) clipped the last row by 14pt.
            .frame(height: max(240, CGFloat(orderedKeys.count) * 30 + 16))

            HStack {
                Spacer()
                Button("Reset Default Order") { model.resetPlatformOrder() }
                    .help("Reset Default Order")
                    .accessibilityLabel("Reset Default Order")
            }
        }
        .padding(Metrics.pagePadding)
        .background {
            // Keyboard equivalents for the drag the chevrons used to stand in for.
            VStack {
                Button("") { moveSelection(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                Button("") { moveSelection(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var keys = orderedKeys
        keys.move(fromOffsets: source, toOffset: destination)
        model.platformOrder = keys
    }

    private func moveSelection(by delta: Int) {
        guard let selection else { return }
        if delta < 0 { model.movePlatformUp(providerKey: selection) }
        else { model.movePlatformDown(providerKey: selection) }
    }
}

// MARK: - Sources & Fleet

struct SettingsSourcesFleetPage: View {
    @ObservedObject var model: MonitorModel

    @State private var syncEndpoint = ""
    @State private var syncToken = ""
    @State private var syncFormat: QuotaSyncFormat = .usageMonitorV2
    @State private var pushing = false
    @State private var pushMessage: String?
    @State private var pushSucceeded = false

    @State private var pullEndpoint = ""
    @State private var pullToken = ""
    /// Draft on/off state for the two fleet groups.  Turning a group on only
    /// unlocks its fields; the setting itself is committed by the group's
    /// Save button, so an empty endpoint can never deadlock the toggle.
    @State private var pushEnabled = false
    @State private var pullEnabled = false
    @State private var pulling = false
    @State private var pullMessage: String?
    @State private var pullSucceeded = false

    private var pushDirty: Bool {
        pushEnabled != model.syncEnabled || syncEndpoint != model.syncEndpoint || syncFormat != model.syncFormat || !syncToken.isEmpty
    }
    private var pullDirty: Bool {
        pullEnabled != model.serverEnabled || pullEndpoint != model.endpoint || !pullToken.isEmpty
    }

    private var dashboardURL: URL? {
        guard let url = URL(string: model.endpoint),
              let scheme = url.scheme, let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)")
    }

    var body: some View {
        SettingsPage {
            thisMacSection
            shareSection
            pullSection
        }
        .onAppear {
            syncEndpoint = model.syncEndpoint
            syncFormat = model.syncFormat
            pullEndpoint = model.endpoint
            pushEnabled = model.syncEnabled
            pullEnabled = model.serverEnabled
        }
        .onChange(of: model.syncEnabled) { _, newValue in pushEnabled = newValue }
        .onChange(of: model.serverEnabled) { _, newValue in pullEnabled = newValue }
    }

    // MARK: This Mac

    private var thisMacSection: some View {
        Section {
            Toggle("Read Agent Quotas on This Mac",
                   isOn: Binding(get: { model.localEnabled }, set: { model.setLocalEnabled($0) }))
            ForEach(ReaderStatus.all, id: \.providerKey) { reader in
                readerRow(reader)
            }
        } header: {
            Eyebrow("THIS MAC")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("AgentBar reads each CLI's own saved credentials in place." + sentenceGap
                     + "It never asks you for a provider API key.")
                Text("A snapshot is written to ~/Library/Application Support/Usage Monitor/quota-windows.json for BotFleet.")
                if let handoffError = model.handoffError {
                    Text(handoffError).foregroundStyle(Theme.warning)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readerRow(_ reader: ReaderStatus) -> some View {
        let section = model.sections.first { $0.providerKey == reader.providerKey }
        let issue = model.issues[reader.providerKey]
        let healthy = issue == nil && !(section?.windows.isEmpty ?? true)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                PlatformLogo(providerKey: reader.providerKey, size: 16)
                Text(section?.providerLabel ?? reader.label)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 110, alignment: .leading)
                Text(reader.source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Image(systemName: healthy ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(healthy ? Theme.accent : Theme.warning)
                    .accessibilityHidden(true)
            }
            if let issue {
                Text(issue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !healthy && model.localEnabled {
                Text("Not signed in locally.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Share This Mac

    private var shareSection: some View {
        Section {
            Toggle("Push Quotas to a Server", isOn: Binding(
                get: { pushEnabled },
                set: { newValue in
                    pushEnabled = newValue
                    if !newValue { model.disableSync() }
                }))
            TextField("Ingest Endpoint", text: $syncEndpoint,
                      prompt: Text("https://usage.example.com/api/ingest/usage"))
                .disabled(!pushEnabled)
                .onSubmit(savePush)
            SecureField("Ingest Token", text: $syncToken,
                        prompt: Text(model.hasSavedSyncToken ? "Saved in Keychain" : "Ingest Token"))
                .disabled(!pushEnabled)
                .onSubmit(savePush)
            Picker("Payload Format", selection: $syncFormat) {
                ForEach(QuotaSyncFormat.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!pushEnabled)

            if pushDirty {
                Text("Unsaved changes").font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            HStack(spacing: 10) {
                if model.hasSavedSyncToken {
                    Button("Forget Ingest Token", role: .destructive) {
                        Task {
                            do {
                                try await model.forgetSyncServer()
                                syncToken = ""
                                pushSucceeded = true
                                pushMessage = "Ingest token removed."
                            } catch {
                                pushSucceeded = false
                                pushMessage = error.localizedDescription
                            }
                        }
                    }
                    .help("Forget Ingest Token")
                    .accessibilityLabel("Forget Ingest Token")
                }
                Spacer()
                if pushing { ProgressView().controlSize(.small) }
                CommitButton(title: "Save & Push Now", prominent: pushDirty, action: savePush)
                    .disabled(!pushEnabled || pushing)
            }
            if let pushMessage {
                Text(pushMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(pushSucceeded ? Theme.accent : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Eyebrow("SHARE THIS MAC")
                    Spacer()
                    Text(model.lastSyncTime.map { "Pushed \($0.formatted(date: .omitted, time: .shortened))" } ?? "Never pushed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
                // The last push failure lives with the group that owns it, so a
                // token the server rejects is visible without pressing anything.
                if let pushError = model.lastSyncError {
                    Text("Last push failed." + sentenceGap + pushError)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Text("The Ingest Token is stored in your Keychain, never in a preference file.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func savePush() {
        pushing = true
        pushMessage = nil
        Task {
            defer { pushing = false }
            do {
                try await model.saveSyncSettings(enabled: pushEnabled,
                                                 endpoint: syncEndpoint,
                                                 token: syncToken,
                                                 format: syncFormat)
                let (ok, message) = await model.testAndPushSync(endpoint: syncEndpoint,
                                                                token: syncToken,
                                                                format: syncFormat)
                syncToken = ""
                pushSucceeded = ok
                pushMessage = message
            } catch {
                pushSucceeded = false
                pushMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Pull The Fleet

    private var pullSection: some View {
        Section {
            Toggle("Show Other Machines' Quotas", isOn: Binding(
                get: { pullEnabled },
                set: { newValue in
                    pullEnabled = newValue
                    if !newValue { model.disableServerPull() }
                }))
            TextField("Quota Endpoint", text: $pullEndpoint,
                      prompt: Text("https://usage.example.com/api/quota-windows"))
                .disabled(!pullEnabled)
                .onSubmit(savePull)
            SecureField("Read Token", text: $pullToken,
                        prompt: Text(model.hasSavedToken ? "Saved in Keychain" : "Read Token"))
                .disabled(!pullEnabled)
                .onSubmit(savePull)

            if pullDirty {
                Text("Unsaved changes").font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            HStack(spacing: 10) {
                if model.hasSavedToken {
                    Button("Forget Read Token", role: .destructive) {
                        Task {
                            do {
                                try await model.forgetServer()
                                pullToken = ""
                                pullSucceeded = true
                                pullMessage = "Read token removed."
                            } catch {
                                pullSucceeded = false
                                pullMessage = error.localizedDescription
                            }
                        }
                    }
                    .help("Forget Read Token")
                    .accessibilityLabel("Forget Read Token")
                }
                Spacer()
                if pulling { ProgressView().controlSize(.small) }
                CommitButton(title: "Save & Fetch Now", prominent: pullDirty, action: savePull)
                    .disabled(!pullEnabled || pulling)
            }
            if let pullMessage {
                Text(pullMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(pullSucceeded ? Theme.accent : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
            HStack {
                Eyebrow("PULL THE FLEET")
                Spacer()
                if let dashboardURL {
                    Button {
                        NSWorkspace.shared.open(dashboardURL)
                    } label: {
                        Label("Open Web Dashboard", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .textCase(nil)
                    .help("Open Web Dashboard")
                    .accessibilityLabel("Open Web Dashboard")
                }
                Text(model.lastPullTime.map { "Pulled \($0.formatted(date: .omitted, time: .shortened))" } ?? "Never pulled")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
                if let pullError = model.serverError {
                    Text("Last pull failed." + sentenceGap + pullError)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            Text("Refreshes every 5 minutes while AgentBar is running.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func savePull() {
        pulling = true
        pullMessage = nil
        Task {
            defer { pulling = false }
            do {
                try await model.saveConnection(local: model.localEnabled,
                                               server: pullEnabled,
                                               endpoint: pullEndpoint,
                                               token: pullToken)
                let (ok, message) = await model.testPullConnection(endpoint: pullEndpoint, token: pullToken)
                pullToken = ""
                pullSucceeded = ok
                pullMessage = message
            } catch {
                pullSucceeded = false
                pullMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// The seven local readers, named by the credential they actually read.
struct ReaderStatus {
    let providerKey: String
    let label: String
    let source: String

    static let all: [ReaderStatus] = [
        ReaderStatus(providerKey: "anthropic", label: "Claude", source: "Claude Code credentials"),
        ReaderStatus(providerKey: "openai", label: "Codex", source: "Codex CLI credentials"),
        ReaderStatus(providerKey: "google-antigravity", label: "Antigravity", source: "Antigravity app or CLI"),
        ReaderStatus(providerKey: "cursor", label: "Cursor", source: "Cursor app session"),
        ReaderStatus(providerKey: "xai", label: "Grok CLI", source: "Grok CLI credentials"),
        ReaderStatus(providerKey: "grok-bot", label: "Grok Bot", source: "Cursor app session"),
        ReaderStatus(providerKey: "minimax", label: "MiniMax", source: "MiniMax CLI credentials"),
    ]
}

// MARK: - Appearance

struct SettingsAppearancePage: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        SettingsPage {
            Section {
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Theme")
                .accessibilityLabel("Theme")
            } footer: {
                Text("Light is the default." + sentenceGap + "System follows your Mac's setting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - About

struct SettingsAboutPage: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState

    private static let projectPage = URL(string: "https://github.com/jaywedgeworth22/agent-bar")!

    private var pushingDetail: String {
        guard model.syncEnabled else { return "Off" }
        guard let host = URL(string: model.syncEndpoint)?.host() else { return "On" }
        return "On · \(host)"
    }
    private var pullingDetail: String {
        guard model.serverEnabled else { return "Off" }
        guard let host = URL(string: model.endpoint)?.host() else { return "On" }
        return "On · \(host)"
    }

    var body: some View {
        SettingsPage {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("AgentBar").font(.system(size: 16, weight: .semibold))
                    Text(AgentBarVersion.display)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                LabeledContent("Pushing quota") { Text(pushingDetail) }
                LabeledContent("Pulling quota") { Text(pullingDetail) }
                LabeledContent("Local readers") { Text(model.localEnabled ? "On" : "Off") }
            }

            Section {
                Button {
                    NSWorkspace.shared.open(Self.projectPage)
                } label: {
                    Label("Project Page", systemImage: "arrow.up.right.square")
                }
                .help("Project Page")
                .accessibilityLabel("Project Page")
            } footer: {
                Text("AgentBar reads quota from agent CLIs already signed in on this Mac." + sentenceGap
                     + "It never stores a provider API key.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A group's single commit-and-exercise button.  Prominent while the group is
/// dirty, plain when it is clean, so the instant-apply-versus-commit asymmetry
/// is visible rather than surprising.
struct CommitButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if prominent {
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action).buttonStyle(.bordered)
            }
        }
        .help(title)
        .accessibilityLabel(title)
    }
}
