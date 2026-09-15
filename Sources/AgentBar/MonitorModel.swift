import Combine
import Foundation
import QuotaCore

enum DisplayMode: String, CaseIterable, Identifiable {
    case menuBar, dock, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .menuBar: return "Menu Bar"
        case .dock: return "Dock"
        case .both: return "Both"
        }
    }
}

public enum MenuBarStyle: String, CaseIterable, Identifiable {
    case symbolOnly = "symbolOnly"
    case symbolAndPercent = "symbolAndPercent"
    case percentOnly = "percentOnly"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .symbolOnly: return "Symbol Only"
        case .symbolAndPercent: return "Symbol & Percentage"
        case .percentOnly: return "Percentage Only"
        }
    }
}

public enum QuotaViewLayout: String, CaseIterable, Identifiable {
    case allAtOnce = "allAtOnce"
    case detailed = "detailed"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .allAtOnce: return "All at Once"
        case .detailed: return "Detailed"
        }
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") }
    }
    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    @Published var menuBarQuotaSelection: String {
        didSet { defaults.set(menuBarQuotaSelection, forKey: "menuBarQuotaSelection") }
    }
    @Published var viewLayout: QuotaViewLayout {
        didSet { defaults.set(viewLayout.rawValue, forKey: "quotaViewLayout") }
    }
    @Published private(set) var response = QuotaResponse(generatedAt: "")
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var issues: [String: String] = [:]
    @Published private(set) var serverError: String?
    @Published private(set) var handoffError: String?
    @Published private(set) var now = Date()

    // Local & Remote Reading
    @Published private(set) var localEnabled: Bool
    @Published private(set) var serverEnabled: Bool
    @Published private(set) var endpoint: String
    @Published private(set) var hasSavedToken: Bool

    // Remote Sync / Push Sharing
    @Published private(set) var syncEnabled: Bool
    @Published private(set) var syncEndpoint: String
    @Published private(set) var syncFormat: QuotaSyncFormat
    @Published private(set) var hasSavedSyncToken: Bool
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var lastSyncStatus: String?
    @Published private(set) var isSyncing = false

    private let defaults: UserDefaults
    private var localWindows: [QuotaWindow] = []
    private var serverWindows: [QuotaWindow] = []
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var request: Task<Void, Never>?
    private var revision = 0
    private let publisher = QuotaPublisher()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .both
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .symbolAndPercent
        menuBarQuotaSelection = defaults.string(forKey: "menuBarQuotaSelection") ?? "auto_lowest_active"
        viewLayout = QuotaViewLayout(rawValue: defaults.string(forKey: "quotaViewLayout") ?? "") ?? .allAtOnce
        localEnabled = defaults.object(forKey: "localEnabled") as? Bool ?? true
        serverEnabled = defaults.bool(forKey: "serverEnabled")
        let savedEndpoint = defaults.string(forKey: "endpoint") ?? "https://usage.jays.services/api/quota-windows"
        endpoint = savedEndpoint
        hasSavedToken = defaults.bool(forKey: "hasSavedToken")

        syncEnabled = defaults.bool(forKey: "syncEnabled")
        syncEndpoint = defaults.string(forKey: "syncEndpoint") ?? "https://usage.jays.services/api/ingest/usage"
        syncFormat = QuotaSyncFormat(rawValue: defaults.string(forKey: "syncFormat") ?? "") ?? .usageMonitorV2
        hasSavedSyncToken = defaults.bool(forKey: "hasSavedSyncToken")
    }

    var sections: [QuotaPlatformSection] { response.platformSections(now: now) }
    var freshWindows: [QuotaWindowSnapshot] {
        sections.flatMap(\.windows).filter {
            $0.isFresh && $0.remainingPercent != nil && !$0.window.isSupplementaryVideoQuota && issues[$0.window.canonicalProviderKey] == nil
        }
    }
    var reportingCount: Int { Set(freshWindows.map { $0.window.canonicalProviderKey }).count }
    var nearCapCount: Int { freshWindows.filter { ($0.remainingPercent ?? 100) <= 20 }.count }
    var nextReset: Date? { freshWindows.compactMap(\.resetAt).filter { $0 > now }.min() }

    /// All individual quotas available for pinning to the menu bar.
    var availableMenuBarQuotas: [(id: String, label: String)] {
        var result: [(id: String, label: String)] = [
            (id: "auto_lowest_active", label: "Lowest Active (> 0%)"),
            (id: "auto_lowest", label: "Lowest (All)"),
        ]
        for section in sections {
            let windows = section.windows.filter { $0.isFresh && $0.remainingPercent != nil && !$0.window.isSupplementaryVideoQuota }
            for snapshot in windows {
                let label = "\(section.providerLabel) · \(snapshot.window.label)"
                result.append((id: snapshot.window.id, label: label))
            }
        }
        return result
    }

    /// The window that should drive the menu bar display.
    var menuBarTargetSnapshot: QuotaWindowSnapshot? {
        switch menuBarQuotaSelection {
        case "auto_lowest_active":
            let nonZero = freshWindows.filter { ($0.remainingPercent ?? 0) > 0 }
            return (nonZero.isEmpty ? freshWindows : nonZero)
                .min(by: { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) })
        case "auto_lowest":
            return freshWindows.min(by: { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) })
        default:
            return freshWindows.first { $0.window.id == menuBarQuotaSelection }
                ?? freshWindows.min(by: { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) })
        }
    }

    var menuBarTitle: String {
        guard menuBarStyle != .symbolOnly else { return "" }
        guard let target = menuBarTargetSnapshot, let pct = target.remainingPercent else { return "—" }
        return "\(Int(pct.rounded()))%"
    }

    var menuBarDetail: String {
        guard let target = menuBarTargetSnapshot else { return "No current quota report" }
        let providerLabel = sections.first { $0.providerKey == target.window.canonicalProviderKey }?.providerLabel ?? target.window.provider
        let pct = target.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        return "\(providerLabel), \(target.window.label): \(pct) remaining"
    }

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    func stop() {
        revision += 1
        request?.cancel()
        request = nil
        isRefreshing = false
        refreshTimer?.invalidate()
        clockTimer?.invalidate()
    }

    // MARK: - Server Pull Settings

    func saveConnection(local: Bool, server: Bool, endpoint input: String, token: String) async throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), QuotaClient.isAllowedEndpoint(url) else { throw QuotaClientError.invalidEndpoint }
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanToken.isEmpty {
            guard !cleanToken.contains("\n"), !cleanToken.contains("\r") else { throw QuotaClientError.invalidToken }
            try await TokenStore.save(cleanToken, server: value, service: TokenStore.readService)
        }
        let savedToken = !cleanToken.isEmpty ? cleanToken : server ? await TokenStore.read(server: value, service: TokenStore.readService) : nil
        if server && savedToken == nil { throw QuotaClientError.invalidToken }
        let saved = savedToken != nil || (value == endpoint && hasSavedToken)
        revision += 1
        request?.cancel()
        request = nil
        isRefreshing = false
        localEnabled = local
        serverEnabled = server
        endpoint = value
        hasSavedToken = saved
        defaults.set(saved, forKey: "hasSavedToken")
        defaults.set(local, forKey: "localEnabled")
        defaults.set(server, forKey: "serverEnabled")
        defaults.set(value, forKey: "endpoint")
        localWindows = []
        serverWindows = []
        response = QuotaResponse(generatedAt: "")
        issues = [:]
        serverError = nil
        lastChecked = nil
        refresh()
    }

    func forgetServer() async throws {
        try await TokenStore.delete(server: endpoint, service: TokenStore.readService)
        hasSavedToken = false
        defaults.set(false, forKey: "hasSavedToken")
        try await saveConnection(local: localEnabled, server: false, endpoint: endpoint, token: "")
    }

    // MARK: - Server Push Sync Settings

    func saveSyncSettings(enabled: Bool, endpoint input: String, token: String, format: QuotaSyncFormat) async throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), QuotaClient.isAllowedEndpoint(url) else {
            throw QuotaPublisherError.invalidEndpoint
        }
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanToken.isEmpty {
            try await TokenStore.save(cleanToken, server: value, service: TokenStore.syncService)
        }
        let savedToken = !cleanToken.isEmpty ? cleanToken : enabled ? await TokenStore.read(server: value, service: TokenStore.syncService) : nil
        let saved = savedToken != nil || (value == syncEndpoint && hasSavedSyncToken)

        syncEnabled = enabled
        syncEndpoint = value
        syncFormat = format
        hasSavedSyncToken = saved

        defaults.set(enabled, forKey: "syncEnabled")
        defaults.set(value, forKey: "syncEndpoint")
        defaults.set(format.rawValue, forKey: "syncFormat")
        defaults.set(saved, forKey: "hasSavedSyncToken")

        if enabled && !localWindows.isEmpty {
            await pushQuotasIfEnabled(windows: localWindows)
        }
    }

    func forgetSyncServer() async throws {
        try await TokenStore.delete(server: syncEndpoint, service: TokenStore.syncService)
        hasSavedSyncToken = false
        defaults.set(false, forKey: "hasSavedSyncToken")
        try await saveSyncSettings(enabled: false, endpoint: syncEndpoint, token: "", format: syncFormat)
    }

    func testAndPushSync() async -> (success: Bool, message: String) {
        guard let url = URL(string: syncEndpoint), QuotaClient.isAllowedEndpoint(url) else {
            return (false, "Invalid endpoint URL.")
        }
        let windowsToPush = localWindows.isEmpty ? AntigravityQuotaGroups.normalize(await Self.readLocalSources().windows) : localWindows
        guard !windowsToPush.isEmpty else {
            return (false, "No local agent quotas available to push.")
        }
        let token = await TokenStore.read(server: syncEndpoint, service: TokenStore.syncService)
        do {
            let result = try await publisher.publish(
                windows: windowsToPush,
                to: url,
                token: token,
                format: syncFormat
            )
            self.lastSyncTime = Date()
            self.lastSyncStatus = result.message
            return (true, result.message)
        } catch {
            let errorDesc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.lastSyncStatus = "Error: \(errorDesc)"
            return (false, errorDesc)
        }
    }

    private func pushQuotasIfEnabled(windows: [QuotaWindow]) async {
        guard syncEnabled, let url = URL(string: syncEndpoint), QuotaClient.isAllowedEndpoint(url), !windows.isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }
        let token = await TokenStore.read(server: syncEndpoint, service: TokenStore.syncService)
        do {
            let result = try await publisher.publish(windows: windows, to: url, token: token, format: syncFormat)
            self.lastSyncTime = Date()
            self.lastSyncStatus = result.message
        } catch {
            self.lastSyncStatus = "Error: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Refresh Loop

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let generation = revision
        let useLocal = localEnabled
        let useServer = serverEnabled
        let currentEndpoint = endpoint
        request = Task { [weak self] in
            async let localRead: LocalQuotaResult? = useLocal ? Self.readLocalSources() : nil
            var newServer: QuotaResponse?
            var failure: String?
            if useServer {
                let token = await TokenStore.read(server: currentEndpoint, service: TokenStore.readService)
                do {
                    guard let url = URL(string: currentEndpoint) else { throw QuotaClientError.invalidEndpoint }
                    guard let token else { throw TokenStore.Failure.read }
                    let client = try QuotaClient(endpoint: url, token: token)
                    newServer = try await client.fetch()
                } catch is CancellationError { return }
                catch { failure = (error as? LocalizedError)?.errorDescription ?? "Unable to refresh the server." }
            }
            let local = await localRead
            guard !Task.isCancelled, let self, self.revision == generation else { return }
            self.now = Date()
            self.lastChecked = self.now
            if let local {
                self.issues = local.issues
                self.localWindows = AntigravityQuotaGroups.normalize(local.windows)
            } else {
                self.issues = [:]
                self.localWindows = []
            }

            // Publish local snapshot to BotFleet on disk
            do {
                if useLocal { try LocalQuotaSnapshot.write(windows: self.localWindows, now: self.now) }
                else { try LocalQuotaSnapshot.remove() }
                self.handoffError = nil
            } catch {
                self.handoffError = "BotFleet quota sharing is unavailable."
            }

            // Push to remote server if enabled
            if self.syncEnabled && !self.localWindows.isEmpty {
                await self.pushQuotasIfEnabled(windows: self.localWindows)
            }

            if let newServer { self.serverWindows = newServer.platformSections(now: self.now).flatMap { $0.windows.map(\.window) } }
            if !useServer { self.serverWindows = [] }
            self.serverError = failure
            let localProviders = Set(self.localWindows.map(\.canonicalProviderKey))
            let supplemental = self.serverWindows.filter { !localProviders.contains($0.canonicalProviderKey) }
            let serverProviders = Set(supplemental.map(\.canonicalProviderKey))
            let merged = self.localWindows.filter { !serverProviders.contains($0.canonicalProviderKey) } + supplemental
            for provider in serverProviders {
                self.issues[provider] = failure.map { "Server refresh failed. Showing the last report. \($0)" }
            }
            self.response = QuotaResponse(generatedAt: ISO8601DateFormatter().string(from: self.now), windows: merged)
            self.isRefreshing = false
            self.request = nil
        }
    }

    private nonisolated static func readLocalSources() async -> LocalQuotaResult {
        async let primary = LocalQuotaReader().read()
        async let cursor = CursorQuotaReader().read()
        async let grokBot = GrokBotQuotaReader().read()
        async let antigravity = AntigravitySummaryReader().read()
        let results = await [primary, cursor, grokBot]
        let summary = await antigravity
        var windows = results.flatMap(\.windows)
        var issues = results.reduce(into: [String: String]()) { $0.merge($1.issues) { _, next in next } }
        if summary.windows.contains(where: { $0.boundedRemainingPercent != nil }) {
            windows.removeAll { $0.canonicalProviderKey == "google-antigravity" }
            windows += summary.windows
            issues["google-antigravity"] = nil
        }
        return LocalQuotaResult(windows: windows, issues: issues)
    }
}

func resetCountdown(_ reset: Date?, now: Date) -> String {
    guard let reset else { return "Reset time unavailable" }
    let seconds = reset.timeIntervalSince(now)
    guard seconds > 0 else { return "Reset passed · awaiting refresh" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
    if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
    return "Resets in \(minutes)m"
}
