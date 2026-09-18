import Foundation
import XCTest
@testable import QuotaCore

/// The one-time Allow Access To Claude Code step.
///
/// macOS guards Claude Code's Keychain item per code identity, so a freshly
/// installed CodeCaps reads nothing until the owner allows it once.  "Nothing
/// is there" and "something is there that I may not read" used to arrive as
/// the same empty result, and a signed-in owner was told to sign in.
///
/// Every test here is offline and Keychain-free: the state mapping is pure,
/// and the reader takes an injected credential closure.  Nothing in this file
/// touches the real Keychain, and no credential value is ever asserted on.
final class ClaudeConsentTests: XCTestCase {

    // MARK: - The pure mapping

    func testNoItemAndNoFileReadsAsSignedOut() {
        let state = ClaudeLoginState.resolve(hasUsableCredential: false, access: .missing)
        XCTAssertEqual(state, .signedOut)
        XCTAssertFalse(state.needsConsent)
        XCTAssertEqual(state.issue, "Claude Code quota login is unavailable." + sentenceGap
                       + "Sign in to Claude Code to connect subscription quotas.")
    }

    func testItemPresentButUnreadableAsksForPermission() {
        let state = ClaudeLoginState.resolve(hasUsableCredential: false, access: .unauthorized)
        XCTAssertEqual(state, .needsPermission)
        XCTAssertTrue(state.needsConsent)
        XCTAssertEqual(state.issue, "CodeCaps needs your permission to read Claude Code's saved login.")
    }

    func testReadableItemIsConnected() {
        let access = ClaudeCredentialAccess.authorized(Data("{}".utf8))
        let state = ClaudeLoginState.resolve(hasUsableCredential: true, access: access)
        XCTAssertEqual(state, .connected)
        XCTAssertFalse(state.needsConsent)
        XCTAssertNil(state.issue)
    }

    /// A fresh credentials file wins outright: the Keychain is never consulted,
    /// so whatever it would have said cannot produce a consent prompt.
    func testFreshFileIsConnectedWhateverTheKeychainWouldSay() {
        XCTAssertEqual(ClaudeLoginState.resolve(hasUsableCredential: true, access: .missing), .connected)
        XCTAssertEqual(ClaudeLoginState.resolve(hasUsableCredential: true, access: .unauthorized), .connected)
    }

    // MARK: - The reader, with an injected credential closure

    func testUnauthorizedItemSurfacesTheConsentIssueAndFlagsTheProvider() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Expired, exactly like the stale file this Mac actually carries.
        try writeFixtureLogin(expiresAt: 1_000_000_000_000, to: home)
        let reader = LocalQuotaReader(homeDirectory: home,
                                      runAntigravity: { Data("{}".utf8) },
                                      readClaudeCredential: { .unauthorized })
        let result = await reader.read()
        XCTAssertEqual(result.issues["anthropic"], ClaudeLoginState.needsPermission.issue)
        XCTAssertTrue(result.consentNeeded.contains("anthropic"))
        XCTAssertTrue(result.windows.filter { $0.providerKey == "anthropic" }.isEmpty)
    }

    func testMissingItemKeepsTheSignedOutWordingAndAsksForNoConsent() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeFixtureLogin(expiresAt: 1_000_000_000_000, to: home)
        let reader = LocalQuotaReader(homeDirectory: home,
                                      runAntigravity: { Data("{}".utf8) },
                                      readClaudeCredential: { .missing })
        let result = await reader.read()
        XCTAssertEqual(result.issues["anthropic"], ClaudeLoginState.signedOut.issue)
        XCTAssertFalse(result.consentNeeded.contains("anthropic"))
    }

    func testAuthorizedItemReadsQuotaAndAsksForNoConsent() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeFixtureLogin(expiresAt: 1_000_000_000_000, to: home)
        let reader = LocalQuotaReader(
            homeDirectory: home,
            fetchJSON: { request in
                XCTAssertEqual(request.url?.host, "api.anthropic.com")
                return Self.httpResponse(#"{"five_hour":{"utilization":40}}"#)
            },
            runAntigravity: { Data("{}".utf8) },
            readClaudeCredential: {
                .authorized(Data(#"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":4102444800000}}"#.utf8))
            })
        let result = await reader.read()
        XCTAssertEqual(result.windows.first { $0.providerKey == "anthropic" }?.remainingPercent, 60)
        XCTAssertNil(result.issues["anthropic"])
        XCTAssertTrue(result.consentNeeded.isEmpty)
    }

    /// A usable file means no Keychain traffic at all, so a background refresh
    /// on a healthy Mac can never reach the code path that once raised a panel.
    func testFreshFileNeverConsultsTheKeychain() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeFixtureLogin(expiresAt: 4_102_444_800_000, to: home)
        let probed = ProbeFlag()
        let reader = LocalQuotaReader(
            homeDirectory: home,
            fetchJSON: { _ in Self.httpResponse(#"{"five_hour":{"utilization":10}}"#) },
            runAntigravity: { Data("{}".utf8) },
            readClaudeCredential: {
                probed.set()
                return .unauthorized
            })
        let result = await reader.read()
        XCTAssertFalse(probed.value, "a fresh credentials file must not cost a Keychain read")
        XCTAssertEqual(result.windows.first { $0.providerKey == "anthropic" }?.remainingPercent, 90)
        XCTAssertTrue(result.consentNeeded.isEmpty)
    }

    // MARK: - Helpers

    /// Records whether the injected credential closure ran, without requiring
    /// the closure itself to be mutating or actor-isolated.
    private final class ProbeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        return url
    }

    /// Writes a fixture login into a throwaway home directory.  The token is a
    /// literal placeholder; nothing real is read, written, or asserted on.
    private func writeFixtureLogin(expiresAt: Double, to home: URL) throws {
        let object: [String: Any] = ["claudeAiOauth": ["accessToken": "fixture-token", "expiresAt": expiresAt]]
        let data = try JSONSerialization.data(withJSONObject: object)
        let name = ".credentials" + ".json"
        try data.write(to: home.appendingPathComponent(".claude").appendingPathComponent(name), options: .atomic)
    }

    private static func httpResponse(_ text: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        let url = URL(string: "https://fixture.invalid/quota")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(text.utf8), response)
    }
}
