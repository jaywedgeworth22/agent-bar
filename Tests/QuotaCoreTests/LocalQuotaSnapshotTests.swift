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
        ]
        try LocalQuotaSnapshot.write(windows: [], issues: unsafe, to: url)
        let raw = try String(contentsOf: url, encoding: .utf8)
        for secret in ["sk-ant-api03-7fQ2xR8mNp4tLv0wZ1cB6yH3jK9dS5gA", "owner.person@example.com",
                       "/Users/someone/.grok/credentials.json", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
                       "refresh_token"] {
            XCTAssertFalse(raw.contains(secret), "the handoff published \(secret)")
        }
        let payload = try JSONDecoder().decode(LocalQuotaSnapshot.Payload.self, from: Data(contentsOf: url))
        // The provider still shows as failing — only the unsafe text is replaced.
        XCTAssertEqual(payload.issues?.count, unsafe.count)
        XCTAssertEqual(Set(payload.issues?.values.map { $0 } ?? []), [LocalQuotaSnapshot.redactedIssue])
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

    func testTheDerivationIsIdempotentAndBoundsTheValue() {
        let window = QuotaWindow(id: "a", provider: "openai", label: "5h", remainingPercent: 140,
                                 isExhausted: true, status: .exhausted, skip: true, skipReason: "stale",
                                 occurredAt: "2026-09-16T19:18:50Z")
        let once = window.normalizedForExport()
        XCTAssertEqual(once.remainingPercent, 100)
        XCTAssertEqual(once.status, .available)
        XCTAssertFalse(once.isExhausted)
        XCTAssertFalse(once.skip)
        XCTAssertNil(once.skipReason)
        XCTAssertEqual(once.normalizedForExport(), once)
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

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
