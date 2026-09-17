import Foundation

/// A credential-free handoff for BotFleet on the same Mac.  Only local quota
/// readings are exported; server accounts and authentication never enter it.
public enum LocalQuotaSnapshot {
    /// Two apps have historically targeted this path.  Naming the writer makes
    /// a collision diagnosable instead of silent.
    public static let producerName = "agent-bar"

    /// The generic reason published in place of an issue string that fails the
    /// safety gate below.  The provider still shows as failing; the unsafe text
    /// never reaches the file.
    static let redactedIssue = "Quota source is unavailable."

    /// `producer` and `issues` are additive and optional on decode, so a file
    /// written by an older build still parses and `version` stays at 1.  The
    /// consumer enforces exact equality on the version, so a bump is a hard
    /// break that has to land in lockstep with it.
    public struct Payload: Codable, Sendable {
        public let format: String
        public let version: Int
        public let producer: String?
        public let generatedAt: String
        public let windows: [QuotaWindow]
        public let issues: [String: String]?

        public init(
            format: String,
            version: Int,
            producer: String? = nil,
            generatedAt: String,
            windows: [QuotaWindow],
            issues: [String: String]? = nil
        ) {
            self.format = format
            self.version = version
            self.producer = producer
            self.generatedAt = generatedAt
            self.windows = windows
            self.issues = issues
        }
    }

    public static func destination(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Usage Monitor/quota-windows.json")
    }

    public static func write(
        windows: [QuotaWindow],
        issues: [String: String] = [:],
        now: Date = Date(),
        to url: URL = destination()
    ) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let published = safeIssues(issues)
        let payload = Payload(format: "usage-monitor-local-quotas", version: 1, producer: producerName,
                              generatedAt: ISO8601DateFormatter().string(from: now),
                              windows: windows.map { $0.normalizedForExport() },
                              issues: published.isEmpty ? nil : published)
        let data = try JSONEncoder().encode(payload)
        guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
        try writePrivately(data, to: url, in: directory, using: manager)
    }

    /// Writes the final 0600 mode onto the temporary file before it is renamed
    /// into place.  `Data.write(options: .atomic)` creates its temporary file at
    /// the process umask and chmods only afterwards, so the published path is
    /// briefly readable at umask width — which matters now that the payload
    /// carries provider reasons.  `rename(2)` is atomic within the directory and
    /// carries the mode across with the inode.
    private static func writePrivately(_ data: Data, to url: URL, in directory: URL, using manager: FileManager) throws {
        let temporary = directory.appendingPathComponent(".quota-windows.\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            // A restrictive umask can only narrow the creation mode, never widen
            // it, so this settles the file at exactly 0600 either way.
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let moved = temporary.withUnsafeFileSystemRepresentation { source in
                url.withUnsafeFileSystemRepresentation { destination -> Int32 in
                    guard let source, let destination else { return -1 }
                    return rename(source, destination)
                }
            }
            guard moved == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// The last gate before provider reasons leave the app.  Reasons are the
    /// exact user-safe sentences the menu shows, so this should never fire —
    /// but the file is read by another process, and a reason that looks like a
    /// credential, an address, or a path to a credential store is replaced with
    /// a generic one rather than published.
    public static func safeIssues(_ issues: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in issues {
            let provider = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !provider.isEmpty, provider.count <= 64, provider.allSatisfy(isProviderKeyCharacter) else { continue }
            let reason = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { continue }
            result[provider] = isUserSafe(reason) ? reason : redactedIssue
        }
        return result
    }

    static func isUserSafe(_ reason: String) -> Bool {
        guard reason.count <= 240, reason.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let lowered = reason.lowercased()
        // Shapes that are a credential wherever they appear in the sentence.
        let markers = ["bearer ", "eyj", "-----begin", "authorization:", "access_token", "accesstoken",
                       "refresh_token", "refreshtoken", "client_secret", "clientsecret", "api_key", "apikey", "password"]
        if markers.contains(where: lowered.contains) { return false }
        // An address names the owner's account rather than the failure.
        if reason.contains("@"),
           reason.range(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", options: .regularExpression) != nil {
            return false
        }
        for token in reason.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let body = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}'\"<>"))
            let lower = body.lowercased()
            // Vendor key prefixes, checked at a word boundary so ordinary words
            // such as "risk-free" or "task_id" are not mistaken for one.
            if ["sk-", "sk_", "ghp_", "gho_", "ghu_", "github_pat_", "xox", "akia", "xai-", "glpat-", "npm_"]
                .contains(where: lower.hasPrefix) { return false }
            // A path that names a credential store, at any depth.
            if lower.contains("/") || lower.contains("\\") {
                if ["credential", "secret", "token", "auth", "keychain", ".env", "id_rsa", ".pem", ".p12", "key"]
                    .contains(where: lower.contains) { return false }
            }
            // A long unbroken run of token characters is a secret, not prose.
            if body.count >= 20, body.allSatisfy(isTokenCharacter),
               body.contains(where: { $0.isNumber }), body.contains(where: { $0.isLetter }) { return false }
        }
        return true
    }

    private static func isProviderKeyCharacter(_ value: Character) -> Bool {
        value.isASCII && (value.isLetter || value.isNumber || value == "-" || value == "_" || value == ".")
    }

    private static func isTokenCharacter(_ value: Character) -> Bool {
        value.isASCII && (value.isLetter || value.isNumber || "-_./+=".contains(value))
    }

    public static func remove(at url: URL = destination()) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
