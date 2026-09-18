import Foundation
import XCTest
@testable import QuotaCore

final class LocalQuotaSnapshotTests: XCTestCase {
    func testWritesVersionedPrivateSnapshotAndRemovesWhenDisabled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota-windows.json")
        let window = QuotaWindow(id: "a", provider: "openai", label: "5h", remainingPercent: 0, occurredAt: "2026-09-13T08:00:00Z")
        try LocalQuotaSnapshot.write(windows: [window], to: url)
        let payload = try JSONDecoder().decode(LocalQuotaSnapshot.Payload.self, from: Data(contentsOf: url))
        XCTAssertEqual(payload.format, "usage-monitor-local-quotas")
        // The consumer enforces exact equality on the version, so the additive
        // keys below must not move it.
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.producer, "agent-bar")
        XCTAssertEqual(payload.windows, [window.normalizedForExport()])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try LocalQuotaSnapshot.remove(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Q4: the reason a provider is missing

    func testPublishesProviderIssuesAndOmitsTheKeyWhenThereAreNone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota-windows.json")
        let reason = "Claude Code quota login is unavailable.  Sign in to Claude Code to connect subscription quotas."
        try LocalQuotaSnapshot.write(windows: [], issues: ["anthropic": reason], to: url)
        let payload = try JSONDecoder().decode(LocalQuotaSnapshot.Payload.self, from: Data(contentsOf: url))
        XCTAssertEqual(payload.issues?["anthropic"], reason)
        XCTAssertTrue(payload.windows.isEmpty)

        try LocalQuotaSnapshot.write(windows: [], to: url)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNil(object?["issues"], "an empty map must stay off the wire so the key means something")
        XCTAssertEqual(object?["producer"] as? String, "agent-bar")
        XCTAssertEqual(object?["version"] as? Int, 1)
    }

    func testNeverPublishesTokensAddressesOrCredentialPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota-windows.json")
        let unsafe = [
            "anthropic": "Rejected token sk-ant-api03-7fQ2xR8mNp4tLv0wZ1cB6yH3jK9dS5gA.",
            "openai": "Sign in again as owner.person@example.com to refresh the plan.",
            "xai": "Could not read /Users/someone/.grok/credentials.json for this account.",
            "cursor": "Session bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 expired.",
            "minimax": "Refresh failed: refresh_token was revoked.",
            // The MiniMax store the reader actually loads.  It names no
            // credential, so only the path rule can stop it.
            "mmx": "Could not read ~/.mmx/config.json for this account.",
            // An ordinary home path publishes the macOS account name.
            "google-antigravity": "Could not read /Users/someone/Library/Application Support/Antigravity/quota.json.",
            // A key that punctuation glues to the word before it.
            "grok-bot": "Rejected token(sk-ant-api03-7fQ2xR8mNp4tLv0wZ1cB6yH3jK9dS5gA).",
        ]
        try LocalQuotaSnapshot.write(windows: [], issues: unsafe, to: url)
        let raw = try String(contentsOf: url, encoding: .utf8)
        for secret in ["sk-ant-api03-7fQ2xR8mNp4tLv0wZ1cB6yH3jK9dS5gA", "owner.person@example.com",
                       "/Users/someone/.grok/credentials.json", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
                       "refresh_token", "~/.mmx/config.json", "/Users/someone/Library"] {
            XCTAssertFalse(raw.contains(secret), "the handoff published \(secret)")
        }
        let payload = try JSONDecoder().decode(LocalQuotaSnapshot.Payload.self, from: Data(contentsOf: url))
        // The provider still shows as failing — only the unsafe text is replaced.
        XCTAssertEqual(payload.issues?.count, unsafe.count)
        XCTAssertEqual(Set(payload.issues?.values.map { $0 } ?? []), [LocalQuotaSnapshot.redactedIssue])
    }

    func testPunctuationDoesNotHideASecretFromTheWordRules() {
        // Each of these defeats a whitespace split: the key is welded to the
        // word before it, so the prefix and entropy rules never see it alone.
        let glued = [
            "Rejected token(sk-ant-api03-7fQ2xR8mNp4tLv0wZ1cB6yH3jK9dS5gA).",
            "Rejected key:eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.",
            "Rejected token\u{2014}7fQ2xR8mNp4tLv0wZ1cB6yH3jK9dS5gA.",
        ]
        for reason in glued {
            XCTAssertFalse(LocalQuotaSnapshot.isUserSafe(reason), "punctuation hid a secret: \(reason)")
        }
        // A home or absolute path is the owner's account name, whatever sits at
        // the end of it.
        for path in ["Could not read ~/.mmx/config.json for this account.",
                     "Could not read /Users/someone/Library/Caches/quota.json.",
                     "Could not read /home/someone/.config/quota.json.",
                     "Could not read /private/var/folders/t9/quota.json."] {
            XCTAssertFalse(LocalQuotaSnapshot.isUserSafe(path), "the gate published a path: \(path)")
        }
    }

    func testKeepsTheUserSafeReasonsTheMenuActuallyShows() {
        let menuReasons = [
            "Claude Code quota login is unavailable.  Sign in to Claude Code to connect subscription quotas.",
            "Codex is not signed in locally.",
            "Grok needs you to sign in again.",
            "Cursor session was rejected; sign in again in Cursor.",
            "Antigravity grouped quota is unavailable.",
            "MiniMax returned no readable quota windows.",
        ]
        for reason in menuReasons {
            XCTAssertTrue(LocalQuotaSnapshot.isUserSafe(reason), "the gate rejected a real menu reason: \(reason)")
        }
        // A blank reason carries nothing, and an unusable key is dropped whole.
        XCTAssertEqual(LocalQuotaSnapshot.safeIssues(["anthropic": "   ", "": "x", "a b": "y"]), [:])
    }

    // MARK: - Q7: one derivation, applied to every window

    func testDerivesStatusForEveryWindowIncludingOnesBuiltWithoutOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota-windows.json")
        // A window built the way AntigravitySummaryReader builds one: no status,
        // no isExhausted, no skip.
        let pool = QuotaWindow(id: "pool", provider: "Antigravity", via: "antigravity", label: "Third-Party Models · Weekly",
                               remainingPercent: 0, window: "weekly", occurredAt: "2026-09-16T19:18:50Z")
        let nearCap = QuotaWindow(id: "near", provider: "Antigravity", via: "antigravity", label: "Gemini Models · 5-hour",
                                  remainingPercent: 8, window: "5h", occurredAt: "2026-09-16T19:18:50Z")
        let unreadable = QuotaWindow(id: "unknown", provider: "Cursor", label: "Included plan",
                                     remainingUnknown: true, occurredAt: "2026-09-16T19:18:50Z")
        try LocalQuotaSnapshot.write(windows: [pool, nearCap, unreadable], to: url)
        let payload = try JSONDecoder().decode(LocalQuotaSnapshot.Payload.self, from: Data(contentsOf: url))
        XCTAssertEqual(payload.windows.map(\.status), [.exhausted, .nearCap, .unknown])
        XCTAssertEqual(payload.windows.map(\.isExhausted), [true, false, false])
        XCTAssertEqual(payload.windows.map(\.skip), [true, false, false])
        XCTAssertEqual(payload.windows.first?.skipReason, "quota exhausted")
        XCTAssertNil(payload.windows.last?.remainingPercent)
    }

    func testTheDerivationFillsWhatIsMissingWithoutErasingWhatTheSourceSaid() {
        // Out of range, and the source left every derived field unset: the
        // percentage is bounded and the rest is filled in from it.
        let unset = QuotaWindow(id: "a", provider: "openai", label: "5h", remainingPercent: 140,
                                occurredAt: "2026-09-16T19:18:50Z")
        let once = unset.normalizedForExport()
        XCTAssertEqual(once.remainingPercent, 100)
        XCTAssertEqual(once.status, .available)
        XCTAssertFalse(once.isExhausted)
        XCTAssertFalse(once.skip)
        XCTAssertNil(once.skipReason)
        XCTAssertEqual(once.normalizedForExport(), once)

        // The source called this one exhausted at 15%.  A rejected session and
        // a suspended plan both look like this, and the percentage is the last
        // good reading rather than the reason, so the derivation must not talk
        // over it.
        let reported = QuotaWindow(id: "b", provider: "openai", label: "5h", remainingPercent: 15,
                                   isExhausted: true, status: .exhausted, skip: true,
                                   skipReason: "session rejected", occurredAt: "2026-09-16T19:18:50Z")
        let kept = reported.normalizedForExport()
        XCTAssertEqual(kept.remainingPercent, 15)
        XCTAssertEqual(kept.status, .exhausted)
        XCTAssertTrue(kept.isExhausted)
        XCTAssertTrue(kept.skip)
        XCTAssertEqual(kept.skipReason, "session rejected")
        XCTAssertEqual(kept.normalizedForExport(), kept)

        XCTAssertEqual(QuotaWindowStatus.derived(remainingPercent: nil), .unknown)
        XCTAssertEqual(QuotaWindowStatus.derived(remainingPercent: 0), .exhausted)
        XCTAssertEqual(QuotaWindowStatus.derived(remainingPercent: 19.9), .nearCap)
        XCTAssertEqual(QuotaWindowStatus.derived(remainingPercent: 20), .available)
    }

    // MARK: - Q11: the mode is final before the file is visible

    func testWritesAtZeroSixHundredEvenUnderAPermissiveUmaskAndLeavesNoTemporary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota-windows.json")
        let previous = umask(0)
        defer { _ = umask(previous) }
        let window = QuotaWindow(id: "a", provider: "openai", label: "5h", remainingPercent: 42, occurredAt: "2026-09-16T19:18:50Z")

        try LocalQuotaSnapshot.write(windows: [window], issues: ["anthropic": "Codex is not signed in locally."], to: url)
        XCTAssertEqual(try mode(of: url), 0o600)
        XCTAssertEqual(try mode(of: directory), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["quota-windows.json"])

        // A rewrite replaces the file rather than reusing a wider inode.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try LocalQuotaSnapshot.write(windows: [window], to: url)
        XCTAssertEqual(try mode(of: url), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["quota-windows.json"])
    }

    /// The test above reads the settled file, and the writer chmods the
    /// published path as the last thing it does — so that test passes whatever
    /// happened in between, including the `Data.write(options: .atomic)` window
    /// this code exists to close.  This one watches the directory from a second
    /// thread for the whole run and fails if the payload is ever on disk, with
    /// content in it, at a mode another local account could read.
    func testThePayloadIsNeverOnDiskAtUmaskWidthWhileItHasContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota-windows.json")
        let previous = umask(0)
        defer { _ = umask(previous) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Enough windows that the moment between creating the temporary file
        // and renaming it is wide enough to sample.
        let windows = (0..<1200).map { index in
            QuotaWindow(id: "local-mac:openai:\(index)", provider: "openai", providerKey: "openai",
                        providerLabel: "OpenAI", sourceApp: "local-mac", label: "5-hour window \(index)",
                        remainingPercent: 42, resetAt: "2026-09-16T23:00:00Z", window: "5h",
                        occurredAt: "2026-09-16T19:18:50Z", source: "OpenAI")
        }
        let watcher = DirectoryModeWatcher(directory: directory)
        watcher.start()
        for _ in 0..<40 {
            try LocalQuotaSnapshot.write(windows: windows, to: url)
        }
        let seen = watcher.stop()
        XCTAssertGreaterThan(seen.filesSeen, 0, "the watcher never saw a file, so it proved nothing")
        XCTAssertEqual(seen.violations, [], "the payload was readable beyond its owner while it held content")
        XCTAssertEqual(try mode(of: url), 0o600)
    }

    /// The temporary file already holds the whole payload by the time the
    /// rename runs, so a failure there is the one that can strand a readable
    /// copy of it next to the real file.
    func testAFailedWriteLeavesNoTemporaryFileBehind() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota-windows.json")
        // A directory sitting on the published path is a target the file cannot
        // be written to, and it fails at `rename(2)` rather than earlier.
        try FileManager.default.createDirectory(at: url.appendingPathComponent("occupied"),
                                                withIntermediateDirectories: true)
        let window = QuotaWindow(id: "a", provider: "openai", label: "5h", remainingPercent: 42,
                                 occurredAt: "2026-09-16T19:18:50Z")
        XCTAssertThrowsError(try LocalQuotaSnapshot.write(windows: [window],
                                                          issues: ["anthropic": "Codex is not signed in locally."],
                                                          to: url))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["quota-windows.json"])
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

/// Polls a directory from another thread and records every entry it finds
/// holding content at a mode wider than 0600.
private final class DirectoryModeWatcher {
    struct Seen {
        var violations: [String]
        var filesSeen: Int
    }

    private let directory: URL
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var running = true
    private var violations: [String] = []
    private var filesSeen = 0

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // At least one sample always happens, so a watcher that never got
            // scheduled cannot pass as a clean run.
            repeat { sample() } while isRunning()
            finished.signal()
        }
    }

    func stop() -> Seen {
        lock.lock()
        running = false
        lock.unlock()
        finished.wait()
        lock.lock()
        defer { lock.unlock() }
        return Seen(violations: violations, filesSeen: filesSeen)
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func sample() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries {
            let path = directory.appendingPathComponent(entry).path
            guard let attributes = try? manager.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.intValue, size > 0,
                  let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue else { continue }
            lock.lock()
            filesSeen += 1
            // A handful of examples says everything; the rest would only make
            // the failure unreadable.
            if mode != 0o600, violations.count < 5 {
                violations.append("\(entry) held \(size) bytes at 0\(String(mode, radix: 8))")
            }
            lock.unlock()
        }
    }
}
