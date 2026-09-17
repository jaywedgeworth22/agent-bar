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
    case summary = "allAtOnce"
    case detailed = "detailed"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .summary: return "Summary"
        case .detailed: return "Detailed"
        }
    }
}

/// Which appearance the app forces.  `system` follows the Mac's own setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }
}

/// Whether a provider's windows were read on this Mac or pulled from the fleet.
enum QuotaOrigin: Equatable, Sendable {
    case local, fleet
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
    @Published var platformOrder: [String] {
        didSet { defaults.set(platformOrder, forKey: "platformOrder") }
    }
    @Published var platformCustomInfo: [String: PlatformCustomInfo] {
        didSet {
            if let data = try? JSONEncoder().encode(platformCustomInfo) {
                defaults.set(data, forKey: "platformCustomInfo")
            }
        }
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
    @Published private(set) var lastPullTime: Date?

    // Presentation
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    @Published var keepConsoleInFront: Bool {
        didSet { defaults.set(keepConsoleInFront, forKey: "consoleKeepInFront") }
    }

    /// Where each provider's windows came from on the last refresh.
    @Published private(set) var originByProvider: [String: QuotaOrigin] = [:]

    private let defaults: UserDefaults
    private var localWindows: [QuotaWindow] = []
    private var serverWindows: [QuotaWindow] = []
    private var fleetWindows: [QuotaWindow] = []
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
        viewLayout = QuotaViewLayout(rawValue: defaults.string(forKey: "quotaViewLayout") ?? "") ?? .summary
        platformOrder = defaults.stringArray(forKey: "platformOrder") ?? []
        if let customData = defaults.data(forKey: "platformCustomInfo"),
           let decoded = try? JSONDecoder().decode([String: PlatformCustomInfo].self, from: customData) {
            platformCustomInfo = decoded
        } else {
            platformCustomInfo = [:]
        }
        localEnabled = defaults.object(forKey: "localEnabled") as? Bool ?? true
        serverEnabled = defaults.bool(forKey: "serverEnabled")
        hasSavedToken = defaults.bool(forKey: "hasSavedToken")
        syncEnabled = defaults.bool(forKey: "syncEnabled")
        hasSavedSyncToken = defaults.bool(forKey: "hasSavedSyncToken")

        // Both endpoints now default to empty, so a fresh install never posts to
        // anyone else's server.  An install that predates this change has no
        // stored endpoint but does have a saved token, so the old default is
        // written forward once and that install keeps working unchanged.
        if defaults.string(forKey: "endpoint") == nil, defaults.bool(forKey: "hasSavedToken") {
            defaults.set(Self.legacyPullEndpoint, forKey: "endpoint")
        }
        if defaults.string(forKey: "syncEndpoint") == nil, defaults.bool(forKey: "hasSavedSyncToken") {
            defaults.set(Self.legacySyncEndpoint, forKey: "syncEndpoint")
        }
        endpoint = defaults.string(forKey: "endpoint") ?? ""
        syncEndpoint = defaults.string(forKey: "syncEndpoint") ?? ""
        syncFormat = QuotaSyncFormat(rawValue: defaults.string(forKey: "syncFormat") ?? "") ?? .usageMonitorV2

        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .light
        keepConsoleInFront = defaults.bool(forKey: "consoleKeepInFront")
    }

    /// The endpoints AgentBar shipped with before the defaults became empty.
    /// Referenced only by the one-time migration in `init`.
    private static let legacyPullEndpoint = "https://usage.jays.services/api/quota-windows"
    private static let legacySyncEndpoint = "https://usage.jays.services/api/ingest/usage"

    var sections: [QuotaPlatformSection] {
        let base = response.platformSections(now: now)
        if platformOrder.isEmpty { return base }
        var orderMap: [String: Int] = [:]
        for (idx, key) in platformOrder.enumerated() {
            orderMap[key] = idx
        }
        return base.sorted { (a, b) -> Bool in
            let idxA = orderMap[a.providerKey] ?? 999
            let idxB = orderMap[b.providerKey] ?? 999
            if idxA != idxB { return idxA < idxB }
            return a.providerLabel < b.providerLabel
        }
    }
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

    func movePlatformUp(providerKey: String) {
        var current = platformOrder.isEmpty ? sections.map(\.providerKey) : platformOrder
        guard let idx = current.firstIndex(of: providerKey), idx > 0 else { return }
        current.swapAt(idx, idx - 1)
        platformOrder = current
    }

    func movePlatformDown(providerKey: String) {
        var current = platformOrder.isEmpty ? sections.map(\.providerKey) : platformOrder
        guard let idx = current.firstIndex(of: providerKey), idx < current.count - 1 else { return }
        current.swapAt(idx, idx + 1)
        platformOrder = current
    }

    func resetPlatformOrder() {
        platformOrder = []
    }

    func setCustomInfo(for providerKey: String, info: PlatformCustomInfo) {
        platformCustomInfo[providerKey] = info
    }

    /// Live binding for the local-readers toggle.  Writing the default and
    /// refreshing in one call is what lets the Settings toggle apply on the spot
    /// instead of waiting for a save.
    func setLocalEnabled(_ value: Bool) {
        guard value != localEnabled else { return }
        localEnabled = value
        defaults.set(value, forKey: "localEnabled")
        refresh()
    }

    /// The distinct `source` strings carried by fleet windows, sorted.  This is
    /// every machine identity the payload actually supports: `QuotaWindow` has a
    /// `source` and no host or producer field, so nothing else can be shown
    /// without inventing it.
    var fleetSourceLabels: [String] {
        var seen = Set<String>()
        for window in fleetWindows {
            let value = (window.source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { seen.insert(value) }
        }
        return seen.sorted()
    }

    var fleetWindowCount: Int { fleetWindows.count }

    // MARK: - Server Pull Settings

    func testPullConnection(endpoint input: String, token inputToken: String) async -> (success: Bool, message: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), QuotaClient.isAllowedEndpoint(url) else {
            return (false, "Invalid endpoint URL." + sentenceGap + "Use HTTPS, or HTTP for localhost only.")
        }
        let cleanToken = inputToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedToken = !cleanToken.isEmpty ? cleanToken : await TokenStore.read(server: value, service: TokenStore.readService)
        guard let token = resolvedToken, !token.isEmpty else {
            return (false, "Please provide a valid Read Token.")
        }
        do {
            let client = try QuotaClient(endpoint: url, token: token)
            let res = try await client.fetch()
            let count = res.windows.count
            return (true, "Connected! Received \(count) quota window\(count == 1 ? "" : "s").")
        } catch {
            let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (false, desc)
        }
    }

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

    func testAndPushSync(endpoint input: String = "", token inputToken: String = "", format inputFormat: QuotaSyncFormat? = nil) async -> (success: Bool, message: String) {
        let endpointValue = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetEndpoint = !endpointValue.isEmpty ? endpointValue : syncEndpoint
        guard let url = URL(string: targetEndpoint), QuotaClient.isAllowedEndpoint(url) else {
            return (false, "Invalid endpoint URL." + sentenceGap + "Use HTTPS, or HTTP for localhost only.")
        }
        let windowsToPush = localWindows.isEmpty ? AntigravityQuotaGroups.normalize(await Self.readLocalSources().windows) : localWindows
        guard !windowsToPush.isEmpty else {
            return (false, "No local agent quotas available to push.")
        }
        let cleanToken = inputToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedToken = !cleanToken.isEmpty ? cleanToken : await TokenStore.read(server: targetEndpoint, service: TokenStore.syncService)
        guard let token = resolvedToken, !token.isEmpty else {
            return (false, "Please provide a valid Ingest Token.")
        }
        let targetFormat = inputFormat ?? syncFormat
        do {
            let result = try await publisher.publish(
                windows: windowsToPush,
                to: url,
                token: token,
                format: targetFormat
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
                catch { failure = (error as? LocalizedError)?.errorDescription ?? "Unable to reach the server." }
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
                // `issues` is still the local read's own map here — the server
                // failure below is merged in afterwards and must never reach a
                // file that promises local-only readings.
                if useLocal { try LocalQuotaSnapshot.write(windows: self.localWindows, issues: self.issues, now: self.now) }
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
            self.fleetWindows = supplemental
            var origins: [String: QuotaOrigin] = [:]
            for key in localProviders { origins[key] = .local }
            for key in serverProviders { origins[key] = .fleet }
            self.originByProvider = origins
            if newServer != nil { self.lastPullTime = self.now }
            for provider in serverProviders {
                self.issues[provider] = failure.map { "Fleet refresh failed." + sentenceGap + "Showing the last report." + sentenceGap + $0 }
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
