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
        case .summary: return "Compact"
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

/// Pulled windows that share one origin, before they are turned into rows.
struct FleetWindowGroup: Equatable {
    let id: String
    let title: String
    let windows: [QuotaWindow]
}

/// One machine's worth of fleet rows.
struct FleetGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let windowCount: Int
    let rows: [DisplaySection]
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
    /// Whether this build can actually read the saved Read Token.  A rebuild
    /// under a different code identity leaves the item on disk and unreadable,
    /// and the owner needs to be told that in words rather than left with a
    /// pull that quietly fails.
    @Published private(set) var readTokenState: SavedTokenState = .none

    // Remote Sync / Push Sharing
    @Published private(set) var syncEnabled: Bool
    @Published private(set) var syncEndpoint: String
    @Published private(set) var syncFormat: QuotaSyncFormat
    @Published private(set) var hasSavedSyncToken: Bool
    /// The same, for the Ingest Token.
    @Published private(set) var syncTokenState: SavedTokenState = .none
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var lastSyncStatus: String?
    /// The last push failure, kept separately from `lastSyncStatus` so Settings
    /// can show it under the group that owns it.
    @Published private(set) var lastSyncError: String?
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
    @Published private(set) var fleetWindowGroups: [FleetWindowGroup] = []
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

        endpoint = defaults.string(forKey: "endpoint") ?? ""
        syncEndpoint = defaults.string(forKey: "syncEndpoint") ?? ""
        syncFormat = QuotaSyncFormat(rawValue: defaults.string(forKey: "syncFormat") ?? "") ?? .usageMonitorV2

        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .light
        keepConsoleInFront = defaults.bool(forKey: "consoleKeepInFront")
    }

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
    /// One row per platform, except Antigravity, which is one row per pool.
    /// Every surface that lists platforms reads this rather than `sections`.
    var displaySections: [DisplaySection] {
        sections.flatMap { DisplaySection.rows(for: $0, now: now) }
    }

    /// Windows whose percentage is real but meaningless: a five-hour Antigravity
    /// window under a pool whose weekly cap is already spent.  They are shown as
    /// "n/a" and never counted as near cap or picked as the lowest.
    var maskedWindowIds: Set<String> {
        AntigravityQuotaGroups.maskedWindowIds(
            in: sections.filter { $0.providerKey == AntigravityDisplay.providerKey }
                .flatMap { $0.windows.map(\.window) },
            now: now)
    }

    var freshWindows: [QuotaWindowSnapshot] {
        let masked = maskedWindowIds
        return sections.flatMap(\.windows).filter {
            $0.isFresh && $0.remainingPercent != nil && !$0.window.isSupplementaryVideoQuota
                && !masked.contains($0.window.id)
                && issues[$0.window.canonicalProviderKey] == nil
        }
    }
    var reportingCount: Int { Set(freshWindows.map { $0.window.canonicalProviderKey }).count }
    var nearCapCount: Int { freshWindows.filter { ($0.remainingPercent ?? 100) <= 20 }.count }
    var nextReset: Date? { freshWindows.compactMap(\.resetAt).filter { $0 > now }.min() }

    /// All individual quotas available for pinning to the menu bar.
    var availableMenuBarQuotas: [(id: String, label: String)] {
        var result: [(id: String, label: String)] = [
            (id: "auto_lowest_active", label: "Lowest active quota"),
            (id: "auto_lowest", label: "Lowest quota"),
        ]
        for row in displaySections {
            let windows = row.section.windows.filter {
                $0.isFresh && $0.remainingPercent != nil && !$0.window.isSupplementaryVideoQuota && !row.isMasked($0)
            }
            for snapshot in windows {
                let label = "\(row.title) · \(AntigravityDisplay.windowLabel(snapshot.window.label))"
                result.append((id: snapshot.window.id, label: label))
            }
        }
        // A pinned window can be absent — a retired platform, a reader that is
        // signed out, a refresh that failed.  Without a matching tag the Picker
        // draws empty and says nothing, so the selection carries its own row
        // rather than being silently dropped, which would lose the pin.
        if !result.contains(where: { $0.id == menuBarQuotaSelection }) {
            result.append((id: menuBarQuotaSelection, label: "Pinned quota unavailable"))
        }
        return result
    }

    /// The row a window belongs to, so the menu bar and the Next Reset tile can
    /// name the Antigravity pool rather than the platform.
    func displayRow(for window: QuotaWindow) -> DisplaySection? {
        displaySections.first { $0.section.windows.contains { $0.window.id == window.id } }
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
        let title = displayRow(for: target.window)?.title
            ?? sections.first { $0.providerKey == target.window.canonicalProviderKey }?.providerLabel
            ?? target.window.provider
        let pct = target.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        return "\(title), \(windowCadenceName(target.window)): \(pct) remaining"
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

    /// Turns push sharing off without needing a valid endpoint.  Turning it on
    /// always goes through `saveSyncSettings`, which validates the endpoint.
    func disableSync() {
        guard syncEnabled else { return }
        syncEnabled = false
        defaults.set(false, forKey: "syncEnabled")
    }

    /// Turns fleet pull off without needing a valid endpoint.  Turning it on
    /// always goes through `saveConnection`, which validates the endpoint.
    func disableServerPull() {
        guard serverEnabled else { return }
        serverEnabled = false
        defaults.set(false, forKey: "serverEnabled")
        refresh()
    }

    /// The distinct origin labels carried by fleet windows, sorted.
    var fleetSourceLabels: [String] { fleetWindowGroups.map(\.title) }

    var fleetWindowCount: Int { fleetWindowGroups.reduce(0) { $0 + $1.windows.count } }

    /// Every pulled window, rendered.  The rows are grouped by the origin the
    /// payload carries, and a group's rows are built exactly like local ones —
    /// including the Antigravity pool split.
    var fleetGroups: [FleetGroup] {
        fleetWindowGroups.map { group in
            let sections = QuotaResponse(generatedAt: "", windows: group.windows)
                .platformSections(now: now)
                .filter { !$0.windows.isEmpty }
            return FleetGroup(id: group.id,
                              title: group.title,
                              windowCount: group.windows.count,
                              rows: sections.flatMap { DisplaySection.rows(for: $0, now: now) })
        }
    }

    // MARK: - Saved Token Availability

    /// Re-reads both saved tokens silently and records what this build can see.
    /// Prompt-free by construction: the interactive read lives behind the
    /// Re-Authorize Saved Token button and is never reached from here.
    func refreshSavedTokenStates() async {
        let readOK = hasSavedToken && !endpoint.isEmpty
            ? await TokenStore.read(server: endpoint, service: TokenStore.readService) != nil
            : false
        let syncOK = hasSavedSyncToken && !syncEndpoint.isEmpty
            ? await TokenStore.read(server: syncEndpoint, service: TokenStore.syncService) != nil
            : false
        readTokenState = SavedTokenState.resolve(hasSavedFlag: hasSavedToken, silentReadSucceeded: readOK)
        syncTokenState = SavedTokenState.resolve(hasSavedFlag: hasSavedSyncToken, silentReadSucceeded: syncOK)
    }

    /// One interactive read, so macOS can show its own panel and the owner can
    /// press Always Allow.  On success the pull is refreshed immediately.
    func reauthorizeReadToken() async -> (success: Bool, message: String) {
        let token = await TokenStore.readAllowingInteraction(server: endpoint, service: TokenStore.readService)
        let ok = !(token.map(sanitizedToken(_:)) ?? "").isEmpty
        readTokenState = SavedTokenState.resolve(hasSavedFlag: hasSavedToken, silentReadSucceeded: ok)
        if ok {
            serverError = nil
            refresh()
            return (true, "The saved token is readable again.")
        }
        return (false, "The saved token is still unavailable." + sentenceGap + "Paste the token again.")
    }

    func reauthorizeSyncToken() async -> (success: Bool, message: String) {
        let token = await TokenStore.readAllowingInteraction(server: syncEndpoint, service: TokenStore.syncService)
        let ok = !(token.map(sanitizedToken(_:)) ?? "").isEmpty
        syncTokenState = SavedTokenState.resolve(hasSavedFlag: hasSavedSyncToken, silentReadSucceeded: ok)
        if ok {
            lastSyncError = nil
            return (true, "The saved token is readable again.")
        }
        return (false, "The saved token is still unavailable." + sentenceGap + "Paste the token again.")
    }

    // MARK: - Server Pull Settings

    func testPullConnection(endpoint input: String, token inputToken: String) async -> (success: Bool, message: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), QuotaClient.isAllowedEndpoint(url) else {
            return (false, "Invalid endpoint URL." + sentenceGap + "Use HTTPS, or HTTP for localhost only.")
        }
        let cleanToken = sanitizedToken(inputToken)
        let resolvedToken = !cleanToken.isEmpty ? cleanToken : await TokenStore.read(server: value, service: TokenStore.readService).map(sanitizedToken(_:))
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
        let cleanToken = sanitizedToken(token)
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
        readTokenState = SavedTokenState.resolve(hasSavedFlag: saved, silentReadSucceeded: savedToken != nil)
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
        readTokenState = .none
        defaults.set(false, forKey: "hasSavedToken")
        try await saveConnection(local: localEnabled, server: false, endpoint: endpoint, token: "")
    }

    // MARK: - Server Push Sync Settings

    func saveSyncSettings(enabled: Bool, endpoint input: String, token: String, format: QuotaSyncFormat) async throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), QuotaClient.isAllowedEndpoint(url) else {
            throw QuotaPublisherError.invalidEndpoint
        }
        let cleanToken = sanitizedToken(token)
        if !cleanToken.isEmpty {
            try await TokenStore.save(cleanToken, server: value, service: TokenStore.syncService)
        }
        let savedToken = !cleanToken.isEmpty ? cleanToken : enabled ? await TokenStore.read(server: value, service: TokenStore.syncService) : nil
        let saved = savedToken != nil || (value == syncEndpoint && hasSavedSyncToken)

        syncEnabled = enabled
        syncEndpoint = value
        syncFormat = format
        hasSavedSyncToken = saved
        syncTokenState = SavedTokenState.resolve(hasSavedFlag: saved, silentReadSucceeded: savedToken != nil)

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
        syncTokenState = .none
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
        let cleanToken = sanitizedToken(inputToken)
        let resolvedToken = !cleanToken.isEmpty ? cleanToken : await TokenStore.read(server: targetEndpoint, service: TokenStore.syncService).map(sanitizedToken(_:))
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
            self.lastSyncError = nil
            return (true, result.message)
        } catch {
            let errorDesc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.lastSyncStatus = "Error: \(errorDesc)"
            self.lastSyncError = errorDesc
            return (false, errorDesc)
        }
    }

    private func pushQuotasIfEnabled(windows: [QuotaWindow]) async {
        guard syncEnabled, let url = URL(string: syncEndpoint), QuotaClient.isAllowedEndpoint(url), !windows.isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }
        let token = await TokenStore.read(server: syncEndpoint, service: TokenStore.syncService).map(sanitizedToken(_:))
        do {
            let result = try await publisher.publish(windows: windows, to: url, token: token, format: syncFormat)
            self.lastSyncTime = Date()
            self.lastSyncStatus = result.message
            self.lastSyncError = nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.lastSyncStatus = "Error: \(message)"
            self.lastSyncError = message
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
            // The pull's own read doubles as the availability check, so the
            // caption below the group header costs no extra Keychain traffic.
            var savedTokenReadable = false
            if useServer {
                let token = await TokenStore.read(server: currentEndpoint, service: TokenStore.readService)
                    .map(sanitizedToken(_:))
                savedTokenReadable = !(token ?? "").isEmpty
                do {
                    guard let url = URL(string: currentEndpoint) else { throw QuotaClientError.invalidEndpoint }
                    guard let token else { throw TokenStore.Failure.read }
                    let client = try QuotaClient(endpoint: url, token: token)
                    newServer = try await client.fetch()
                } catch is CancellationError { return }
                catch {
                    failure = (error as? LocalizedError)?.errorDescription
                        ?? ("Unable to reach the server." + sentenceGap + "Check the Quota Endpoint and the Read Token.")
                }
            }
            let local = await localRead
            guard !Task.isCancelled, let self, self.revision == generation else { return }
            if useServer {
                self.readTokenState = SavedTokenState.resolve(hasSavedFlag: self.hasSavedToken,
                                                              silentReadSucceeded: savedTokenReadable)
            }
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

            if let newServer {
                // The raw windows, deliberately: running them through
                // `platformSections` first pools every Antigravity model report
                // into four windows and keeps only one observation's origin, so
                // a second producer's readings vanished before they could be
                // grouped.  Each origin group is sectioned on its own below.
                self.serverWindows = newServer.windows.isEmpty
                    ? newServer.providerGroups.flatMap(\.windows)
                    : newServer.windows
            }
            if !useServer { self.serverWindows = [] }
            self.serverError = failure
            let localProviders = Set(self.localWindows.map(\.canonicalProviderKey))

            // A pulled window is either this Mac's own push coming back, or
            // somebody else's reading.  Every window of the second kind is
            // rendered under FLEET, grouped by its origin — the previous
            // "supplemental" filter dropped all of them on a Mac that reads
            // every provider locally, so a working pull showed nothing at all.
            let split = FleetOrigin.split(self.serverWindows)
            let ownPush = split.ownPush
            self.fleetWindowGroups = split.groups.map {
                FleetWindowGroup(id: $0.id, title: $0.title, windows: $0.windows)
            }

            // This Mac's own push fills in only a provider no local reader
            // produced — with local readers off, that is every provider.
            let adopted = ownPush.filter { !localProviders.contains($0.canonicalProviderKey) }
            let merged = self.localWindows + adopted
            var origins: [String: QuotaOrigin] = [:]
            for key in Set(merged.map(\.canonicalProviderKey)) { origins[key] = .local }
            self.originByProvider = origins
            if newServer != nil { self.lastPullTime = self.now }
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
