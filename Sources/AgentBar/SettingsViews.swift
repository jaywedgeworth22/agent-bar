import AppKit
import QuotaCore
import SwiftUI

struct MonitorSettings: View {
    @ObservedObject var model: MonitorModel

    // Local / Pull state
    @State private var local = true
    @State private var server = false
    @State private var endpoint = ""
    @State private var token = ""
    @State private var testingPull = false
    @State private var testPullMessage: String?
    @State private var testPullSuccess = false

    // Sync / Push state
    @State private var syncEnabled = false
    @State private var syncEndpoint = ""
    @State private var syncToken = ""
    @State private var syncFormat: QuotaSyncFormat = .usageMonitorV2
    @State private var testingPush = false
    @State private var testResultMessage: String?
    @State private var testResultSuccess = false

    // Platforms customization
    @State private var selectedPlatformKey: String = "google-antigravity"
    @State private var customSubtitleInput: String = ""
    @State private var planNameInput: String = ""
    @State private var costUsdInput: String = ""
    @State private var renewalDateInput: String = ""
    @State private var showCostAndRenewalInput: Bool = false

    @State private var message: String?
    @State private var isError = false
    @State private var saving = false
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AgentBar Settings").font(.title2.bold())
                Spacer()
            }

            Picker("", selection: $selectedTab) {
                Text("General").tag(0)
                Text("Platforms").tag(1)
                Text("Sync & Share").tag(2)
                Text("Pull Fleet").tag(3)
            }
            .pickerStyle(.segmented)

            Group {
                if selectedTab == 0 {
                    generalTab
                } else if selectedTab == 1 {
                    platformsTab
                } else if selectedTab == 2 {
                    syncAndShareTab
                } else {
                    pullFleetTab
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if let message {
                Text(message).font(.caption).foregroundStyle(isError ? Theme.danger : Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                if selectedTab == 2 && model.hasSavedSyncToken {
                    Button("Forget Sync Token", role: .destructive) {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                try await model.forgetSyncServer()
                                syncToken = ""
                                message = "Sync token removed."
                                isError = false
                            } catch {
                                message = error.localizedDescription
                                isError = true
                            }
                        }
                    }
                } else if selectedTab == 3 && model.hasSavedToken {
                    Button("Forget Read Token", role: .destructive) {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                try await model.forgetServer()
                                server = false
                                token = ""
                                message = "Fleet read token removed."
                                isError = false
                            } catch {
                                message = error.localizedDescription
                                isError = true
                            }
                        }
                    }
                }
                Spacer()
                Button("Save Settings") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            try await model.saveConnection(local: local, server: server, endpoint: endpoint, token: token)
                            try await model.saveSyncSettings(enabled: syncEnabled, endpoint: syncEndpoint, token: syncToken, format: syncFormat)
                            saveCurrentPlatformCustomInfo()
                            token = ""
                            syncToken = ""
                            message = "Settings saved successfully."
                            isError = false
                        } catch {
                            message = error.localizedDescription
                            isError = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            if saving { ProgressView("Saving settings…").font(.caption) }
        }
        .disabled(saving)
        .padding(24).frame(width: 620, height: 560).tint(Theme.accent)
        .onAppear {
            local = model.localEnabled
            server = model.serverEnabled
            endpoint = model.endpoint
            syncEnabled = model.syncEnabled
            syncEndpoint = model.syncEndpoint
            syncFormat = model.syncFormat
            loadPlatformCustomInfo(for: selectedPlatformKey)
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Appearance") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Show In", selection: $model.displayMode) {
                        ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("AgentBar runs in the menu bar, Dock, or both.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }

            GroupBox("Menu Bar") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Style").font(.caption.weight(.medium))
                        Picker("Style", selection: $model.menuBarStyle) {
                            ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Displayed Quota").font(.caption.weight(.medium))
                        Picker("Displayed Quota", selection: $model.menuBarQuotaSelection) {
                            ForEach(model.availableMenuBarQuotas, id: \.id) { item in
                                Text(item.label).tag(item.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }

                    Text(model.menuBarStyle == .symbolOnly
                         ? "Only the icon is visible in the menu bar (matching the targeted agent) — click it to view all quotas."
                         : "Shows \"\(model.menuBarTitle.isEmpty ? "..." : model.menuBarTitle)\" with the agent icon from \(model.menuBarDetail).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }

            GroupBox("Local Quota Readers") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Read Agent Quotas on This Mac", isOn: $local)
                    Text("Automatically reads Claude Code Keychain credentials, Codex CLI, Google Antigravity summary/CLI, Cursor, Grok CLI, Grok Bot, and MiniMax sessions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("• Atomic local handoff published at ~/Library/Application Support/Usage Monitor/quota-windows.json for BotFleet.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }.padding(8)
            }
        }
    }

    private var platformsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Platform Display Order & Subscription Details") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select a platform to rearrange order or customize its subscription text, cost, and renewal date.")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 14) {
                        // Platform List with Reorder Buttons
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Platforms (Top to Bottom)").font(.caption.weight(.semibold))
                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(model.sections, id: \.providerKey) { section in
                                        HStack(spacing: 6) {
                                            PlatformLogo(providerKey: section.providerKey, size: 16)
                                            Text(section.providerLabel)
                                                .font(.system(size: 11, weight: selectedPlatformKey == section.providerKey ? .bold : .regular))
                                                .lineLimit(1)
                                            Spacer()
                                            Button {
                                                model.movePlatformUp(providerKey: section.providerKey)
                                            } label: { Image(systemName: "chevron.up").font(.system(size: 9)) }
                                            .buttonStyle(.plain)

                                            Button {
                                                model.movePlatformDown(providerKey: section.providerKey)
                                            } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(selectedPlatformKey == section.providerKey ? Theme.accent.opacity(0.12) : Theme.hairline, in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            saveCurrentPlatformCustomInfo()
                                            selectedPlatformKey = section.providerKey
                                            loadPlatformCustomInfo(for: section.providerKey)
                                        }
                                    }
                                }
                            }
                            .frame(width: 210, height: 210)

                            Button("Reset Default Order") {
                                model.resetPlatformOrder()
                            }
                            .font(.caption2)
                        }

                        Divider()

                        // Custom Subtitle & Subscription Info
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Edit: \(model.sections.first(where: { $0.providerKey == selectedPlatformKey })?.providerLabel ?? selectedPlatformKey)")
                                .font(.caption.weight(.semibold))

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Custom Subtitle (replaces default text)").font(.caption2)
                                TextField("e.g. Pro tier, Custom text, etc.", text: $customSubtitleInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                            }

                            Divider()

                            Toggle("Display Plan, Cost & Renewal", isOn: $showCostAndRenewalInput)
                                .font(.caption)

                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Plan Name").font(.caption2)
                                    TextField("e.g. Max 20x, Pro", text: $planNameInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                        .disabled(!showCostAndRenewalInput)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Cost").font(.caption2)
                                    TextField("e.g. $20/mo", text: $costUsdInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                        .disabled(!showCostAndRenewalInput)
                                }
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Renewal Date").font(.caption2)
                                TextField("e.g. Oct 12 or Monthly", text: $renewalDateInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                    .disabled(!showCostAndRenewalInput)
                            }
                        }
                    }
                }.padding(8)
            }
        }
    }

    private func loadPlatformCustomInfo(for key: String) {
        if let existing = model.platformCustomInfo[key] {
            customSubtitleInput = existing.customSubtitle
            planNameInput = existing.planName
            costUsdInput = existing.costUsd
            renewalDateInput = existing.renewalDateText
            showCostAndRenewalInput = existing.showCostAndRenewal
        } else {
            customSubtitleInput = ""
            planNameInput = ""
            costUsdInput = ""
            renewalDateInput = ""
            showCostAndRenewalInput = false
        }
    }

    private func saveCurrentPlatformCustomInfo() {
        let info = PlatformCustomInfo(
            customSubtitle: customSubtitleInput,
            planName: planNameInput,
            costUsd: costUsdInput,
            renewalDateText: renewalDateInput,
            showCostAndRenewal: showCostAndRenewalInput
        )
        model.setCustomInfo(for: selectedPlatformKey, info: info)
    }

    private var syncAndShareTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Publish Quotas to Server / Webhook") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Quota Sync", isOn: $syncEnabled)
                    Text("Pushes your Mac's current agent quota percentages and reset countdowns to your usage dashboard or any custom webhook. Credentials never leave RAM.")
                        .font(.caption).foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ingest Endpoint URL").font(.caption.weight(.medium))
                        TextField("https://usage.jays.services/api/ingest/usage", text: $syncEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!syncEnabled)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ingest Token (Stored in Keychain)").font(.caption.weight(.medium))
                        SecureField(model.hasSavedSyncToken ? "Token saved · enter to replace" : "Server Ingest Token (USAGE_INGEST_TOKEN)", text: $syncToken)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!syncEnabled)
                    }

                    Picker("Payload Format", selection: $syncFormat) {
                        ForEach(QuotaSyncFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!syncEnabled)

                    HStack(spacing: 12) {
                        Button("Test & Push Now") {
                            testingPush = true
                            testResultMessage = nil
                            Task {
                                defer { testingPush = false }
                                let (ok, msg) = await model.testAndPushSync(
                                    endpoint: syncEndpoint,
                                    token: syncToken,
                                    format: syncFormat
                                )
                                testResultSuccess = ok
                                testResultMessage = msg
                            }
                        }
                        .disabled(!syncEnabled || testingPush)

                        if testingPush {
                            ProgressView().scaleEffect(0.7)
                        } else if let testResultMessage {
                            Text(testResultMessage)
                                .font(.caption)
                                .foregroundStyle(testResultSuccess ? Theme.accent : Theme.danger)
                                .lineLimit(2)
                        }
                    }

                    Text("Push uses USAGE_INGEST_TOKEN (write permission for POST /api/ingest/usage). Stored in Keychain.")
                        .font(.caption2).foregroundStyle(.secondary)

                    if let lastSyncTime = model.lastSyncTime {
                        HStack {
                            Text("Last pushed: \(lastSyncTime.formatted(date: .omitted, time: .standard))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let status = model.lastSyncStatus {
                                Text("(\(status))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }.padding(8)
            }
        }
    }

    private var pullFleetTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Pull Remote Fleet Quotas (Optional)") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Connect Usage Monitor Server", isOn: $server)
                    Text("Fetches aggregated quotas from remote machines and cloud runners via GET /api/quota-windows.")
                        .font(.caption).foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quota Endpoint").font(.caption.weight(.medium))
                        TextField("https://usage.jays.services/api/quota-windows", text: $endpoint)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Quota Endpoint").disabled(!server)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Read Token (Stored in Keychain)").font(.caption.weight(.medium))
                        SecureField(model.hasSavedToken ? "Token saved · enter to replace" : "Usage Monitor read token (USAGE_READ_TOKEN)", text: $token)
                            .textFieldStyle(.roundedBorder).disabled(!server).accessibilityLabel("Usage Monitor read token")
                    }

                    HStack(spacing: 12) {
                        Button("Test Read Connection") {
                            testingPull = true
                            testPullMessage = nil
                            Task {
                                defer { testingPull = false }
                                let (ok, msg) = await model.testPullConnection(endpoint: endpoint, token: token)
                                testPullSuccess = ok
                                testPullMessage = msg
                            }
                        }
                        .disabled(!server || testingPull)

                        if testingPull {
                            ProgressView().scaleEffect(0.7)
                        } else if let testPullMessage {
                            Text(testPullMessage)
                                .font(.caption)
                                .foregroundStyle(testPullSuccess ? Theme.accent : Theme.danger)
                                .lineLimit(1)
                        }
                    }

                    Text("Pull uses USAGE_READ_TOKEN (read permission for GET /api/quota-windows). Stored in Keychain. Refreshes every 5 minutes while running.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(8)
            }
        }
    }
}
