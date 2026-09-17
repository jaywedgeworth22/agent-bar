import XCTest
@testable import QuotaCore

/// The two Antigravity pools are summarised independently.  Before this, one
/// exhausted weekly cap on the Claude/GPT pool pulled the whole platform to 0%
/// while the Gemini pool was still nearly full.
final class AntigravityPoolsTests: XCTestCase {
    private let observedAt = "2026-09-13T10:00:00Z"
    private let now = ISO8601DateFormatter().date(from: "2026-09-13T10:05:00Z")!

    func testEachPoolTakesTheMinimumOfItsOwnWindowsOnly() throws {
        let windows = AntigravityQuotaGroups.normalize(
            [report("gemini-pro", 89), report("gemini-pro", 94, period: "weekly"),
             report("claude-sonnet", 100), report("claude-sonnet", 12, period: "weekly")],
            includeMissing: true)
        let pools = AntigravityQuotaGroups.pools(from: windows, now: now)
        XCTAssertEqual(pools.map(\.key), ["gemini", "third-party"])
        XCTAssertEqual(pools.map(\.remainingPercent), [89, 12])
        XCTAssertEqual(try XCTUnwrap(pools.first).drivingWindowId, "antigravity:gemini:5h")
        XCTAssertEqual(pools.last?.drivingWindowId, "antigravity:third-party:weekly")
        XCTAssertTrue(pools.allSatisfy { $0.windows.count == 2 })
    }

    func testAnExhaustedWeeklyMasksItsOwnFiveHourWindowAndNoOther() throws {
        let windows = AntigravityQuotaGroups.normalize(
            [report("gemini-pro", 89), report("gemini-pro", 94, period: "weekly"),
             report("claude-sonnet", 100), report("claude-sonnet", 0, period: "weekly")],
            includeMissing: true)
        let pools = AntigravityQuotaGroups.pools(from: windows, now: now)
        let gemini = try XCTUnwrap(pools.first { $0.key == "gemini" })
        let thirdParty = try XCTUnwrap(pools.first { $0.key == "third-party" })

        XCTAssertFalse(gemini.weeklyExhausted)
        XCTAssertTrue(gemini.maskedWindowIds.isEmpty)
        XCTAssertEqual(gemini.remainingPercent, 89)

        XCTAssertTrue(thirdParty.weeklyExhausted)
        XCTAssertEqual(thirdParty.maskedWindowIds, ["antigravity:third-party:5h"])
        // The pool is spent, so the headline is the weekly zero and never the
        // five-hour window's meaningless 100%.
        XCTAssertEqual(thirdParty.remainingPercent, 0)
        XCTAssertEqual(thirdParty.drivingWindowId, "antigravity:third-party:weekly")

        XCTAssertEqual(AntigravityQuotaGroups.maskedWindowIds(in: windows, now: now),
                       ["antigravity:third-party:5h"])
    }

    func testAStaleObservationNeverSetsTheHeadlineNumber() {
        let windows = AntigravityQuotaGroups.normalize([report("gemini-pro", 89)], includeMissing: true)
        let stale = ISO8601DateFormatter().date(from: "2026-09-13T18:00:00Z")!
        XCTAssertNil(AntigravityQuotaGroups.pools(from: windows, now: stale).first?.remainingPercent)
        XCTAssertEqual(AntigravityQuotaGroups.pools(from: windows, now: now).first?.remainingPercent, 89)
    }

    func testPoolsIgnoreOtherProvidersAndUnclassifiableWindows() {
        let other = QuotaWindow(id: "anthropic-5h", provider: "anthropic", label: "5h window",
                                remainingPercent: 10, occurredAt: observedAt)
        let unknown = QuotaWindow(id: "antigravity:mystery", provider: "Antigravity", via: "antigravity",
                                  label: "Mystery Models · 5-hour", remainingPercent: 3,
                                  window: "5h", occurredAt: observedAt)
        let windows = AntigravityQuotaGroups.normalize([report("gemini-pro", 89)])
        let pools = AntigravityQuotaGroups.pools(from: windows + [other, unknown], now: now)
        XCTAssertEqual(pools.map(\.key), ["gemini"])
        XCTAssertEqual(pools.first?.remainingPercent, 89)
    }

    func testPoolAndCadenceKeysAreReadableFromAGroupedWindow() throws {
        let windows = AntigravityQuotaGroups.normalize(
            [report("gemini-pro", 89), report("claude-sonnet", 40, period: "weekly")], includeMissing: true)
        let fiveHour = try XCTUnwrap(windows.first { $0.id == "antigravity:gemini:5h" })
        let weekly = try XCTUnwrap(windows.first { $0.id == "antigravity:third-party:weekly" })
        XCTAssertEqual(AntigravityQuotaGroups.poolKey(for: fiveHour), "gemini")
        XCTAssertEqual(AntigravityQuotaGroups.cadenceKey(for: fiveHour), "5h")
        XCTAssertEqual(AntigravityQuotaGroups.poolKey(for: weekly), "third-party")
        XCTAssertEqual(AntigravityQuotaGroups.cadenceKey(for: weekly), "weekly")
    }

    private func report(_ model: String, _ percent: Double, period: String? = nil) -> QuotaWindow {
        QuotaWindow(id: model + (period ?? ""), provider: "Antigravity", via: "antigravity", sourceApp: "local-mac",
                    modelId: model, label: model, remainingPercent: percent, resetAt: "2026-09-13T15:00:00Z",
                    window: period, occurredAt: observedAt)
    }
}
