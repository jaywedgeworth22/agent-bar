import XCTest
@testable import CodeCaps

/// `TokenStore` talks to the real Keychain, so only its pure parts are pinned
/// here: which service name a bundle identifier produces, and the state that
/// decides whether a settings group offers Re-Authorize Saved Token.
final class TokenStoreTests: XCTestCase {

    // MARK: Service names

    /// The installed app has to keep the exact service names its existing
    /// Keychain items already carry, or the owner's saved tokens disappear.
    func testReleaseIdentifierKeepsTheShippedServiceNames() {
        XCTAssertEqual(TokenStore.serviceName(suffix: "read-token", bundleIdentifier: "com.jays.agent-bar.mac"),
                       "com.jays.agent-bar.mac.read-token")
        XCTAssertEqual(TokenStore.serviceName(suffix: "sync-token", bundleIdentifier: "com.jays.agent-bar.mac"),
                       "com.jays.agent-bar.mac.sync-token")
    }

    /// A dev build gets its own items, so it can never overwrite or forget the
    /// installed app's tokens.
    func testDevIdentifierGetsItsOwnServiceNames() {
        XCTAssertEqual(TokenStore.serviceName(suffix: "read-token", bundleIdentifier: "com.jays.agent-bar.mac.dev"),
                       "com.jays.agent-bar.mac.dev.read-token")
        XCTAssertNotEqual(TokenStore.serviceName(suffix: "read-token", bundleIdentifier: "com.jays.agent-bar.mac.dev"),
                          TokenStore.serviceName(suffix: "read-token", bundleIdentifier: "com.jays.agent-bar.mac"))
    }

    /// Run from a test host or straight out of `.build` there is no bundle
    /// identifier, and the release name is the safe answer.
    func testMissingOrBlankIdentifierFallsBackToTheReleaseName() {
        for identifier in [nil, "", "   ", "\n"] as [String?] {
            XCTAssertEqual(TokenStore.serviceName(suffix: "read-token", bundleIdentifier: identifier),
                           "com.jays.agent-bar.mac.read-token")
        }
    }

    // MARK: Re-authorize caption

    func testNothingSavedNeedsNoAuthorization() {
        let state = SavedTokenState.resolve(hasSavedFlag: false, silentReadSucceeded: false)
        XCTAssertEqual(state, .none)
        XCTAssertFalse(state.needsReauthorization)
    }

    func testSavedAndReadableNeedsNoAuthorization() {
        let state = SavedTokenState.resolve(hasSavedFlag: true, silentReadSucceeded: true)
        XCTAssertEqual(state, .readable)
        XCTAssertFalse(state.needsReauthorization)
    }

    /// The case the owner actually hit: the flag says a token was saved, and
    /// this build's silent read comes back empty because it is not on the
    /// item's access list.
    func testSavedButUnreadableAsksForAuthorization() {
        let state = SavedTokenState.resolve(hasSavedFlag: true, silentReadSucceeded: false)
        XCTAssertEqual(state, .unreadable)
        XCTAssertTrue(state.needsReauthorization)
    }

    /// A read that succeeds while nothing is on file is still nothing on file —
    /// the flag governs, so a stale read can never light the caption.
    func testFlagGovernsOverTheReadResult() {
        XCTAssertEqual(SavedTokenState.resolve(hasSavedFlag: false, silentReadSucceeded: true), .none)
    }
}
