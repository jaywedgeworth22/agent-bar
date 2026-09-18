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

    /// Opens the temporary file at 0600 and writes the payload into that
    /// descriptor, so the bytes are never on disk at a wider mode.  Neither
    /// `Data.write(options: .atomic)` nor
    /// `FileManager.createFile(atPath:contents:attributes:)` can do this: both
    /// write the contents through a temporary of their own at the process umask
    /// and apply the mode only afterwards, leaving the whole payload readable
    /// at umask width for the length of the write — which matters now that it
    /// carries provider reasons, and which the directory mode does not cover,
    /// because the directory is shared with the consumer and may already exist
    /// at 0755.  `rename(2)` is atomic within the directory and carries the mode
    /// across with the inode.
    private static func writePrivately(_ data: Data, to url: URL, in directory: URL, using manager: FileManager) throws {
        let temporary = directory.appendingPathComponent(".quota-windows.\(UUID().uuidString).tmp")
        // `O_EXCL` so a name already on disk is never written through, and 0600
        // in the creation mode so the file is private before it holds a byte.
        // A restrictive umask can only narrow that, never widen it.
        let descriptor = temporary.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Foundation.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var isOpen = true
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            try handle.close()
            isOpen = false
            // An inherited default ACL is the one thing the creation mode cannot
            // settle, so state it once more before the file becomes visible.
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let moved = temporary.withUnsafeFileSystemRepresentation { source in
                url.withUnsafeFileSystemRepresentation { destination -> Int32 in
                    guard let source, let destination else { return -1 }
                    return rename(source, destination)
                }
            }
            guard moved == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            if isOpen { _ = Foundation.close(descriptor) }
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
        // Split on every character a secret cannot contain, so a key glued to a
        // neighbouring word by punctuation — `token(sk-...)`, `key:eyJ...`, an
        // em-dash join — is still weighed as a word of its own rather than
        // hiding inside one that fails every check below.  `~` and `\` stay
        // inside a word so a path is not minced into harmless-looking pieces.
        for token in reason.split(whereSeparator: { !isWordCharacter($0) }) {
            let body = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}'\"<>"))
            let lower = body.lowercased()
            // Vendor key prefixes, checked at a word boundary so ordinary words
            // such as "risk-free" or "task_id" are not mistaken for one.
            if ["sk-", "sk_", "ghp_", "gho_", "ghu_", "github_pat_", "xox", "akia", "xai-", "glpat-", "npm_"]
                .contains(where: lower.hasPrefix) { return false }
            // An absolute or home path names the account this Mac belongs to,
            // and the store at the end of it is routinely one the keyword list
            // below has no name for.  A reason can say a source is unreadable
            // without saying where on this disk it lives.
            if ["/users/", "/home/", "/private/", "~/", "/library/"].contains(where: lower.contains) { return false }
            // A path that names a credential store, at any depth.  `.mmx` holds
            // the MiniMax key the reader loads, so it belongs on the list.
            if lower.contains("/") || lower.contains("\\") {
                if ["credential", "secret", "token", "auth", "keychain", ".env", "id_rsa", ".pem", ".p12", "key", ".mmx"]
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

    /// What a word may be built from for the scan above: every character a
    /// secret can carry, plus the `~` and `\` that hold a path together.
    private static func isWordCharacter(_ value: Character) -> Bool {
        isTokenCharacter(value) || value == "~" || value == "\\"
    }

    public static func remove(at url: URL = destination()) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
