import XCTest
@testable import QuotaCore

final class AntigravityQuotaGroupsTests: XCTestCase {
    func testSharedPoolsProduceExactlyFourRowsWithoutAddingModelQuotas() {
        let reports = [report("gemini-pro", 80), report("gemini-flash", 80),
                       report("claude-sonnet", 40), report("gpt-oss", 40),
                       report("gemini-pro", 25, period: "7d"), report("claude-sonnet", 10, period: "weekly")]
        let groups = AntigravityQuotaGroups.normalize(reports, includeMissing: true)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.map(\.remainingPercent), [80, 25, 40, 10])
        XCTAssertEqual(groups.map(\.label), ["Gemini Models · 5-hour", "Gemini Models · Weekly", "Third-Party Models · 5-hour", "Third-Party Models · Weekly"])
        XCTAssertTrue(groups.allSatisfy { $0.modelId == nil && $0.absoluteLimit == nil })
        XCTAssertEqual(AntigravityQuotaGroups.normalize(groups, includeMissing: true), groups)
    }

    func testMissingWeeklyDoesNotReuseShortPercentageOrReset() {
        let groups = AntigravityQuotaGroups.normalize([report("gemini-pro", 81), report("claude-sonnet", 0)], includeMissing: true)
        XCTAssertEqual(groups.filter { $0.window == "weekly" }.count, 2)
        for weekly in groups.filter({ $0.window == "weekly" }) {
            XCTAssertNil(weekly.remainingPercent)
            XCTAssertNil(weekly.resetAt)
            XCTAssertTrue(weekly.remainingUnknown)
            XCTAssertFalse(QuotaWindowSnapshot(window: weekly).isFresh)
        }
        XCTAssertEqual(groups.first { $0.id == "antigravity:third-party:5h" }?.remainingPercent, 0)
    }

    func testNewestSharedObservationWinsAndTiesUseLowest() {
        var latest = report("gemini-flash", 75)
        latest.occurredAt = "2026-09-13T10:01:00Z"
        let groups = AntigravityQuotaGroups.normalize([report("gemini-pro", 60), latest, report("gemini-flash", 90)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.remainingPercent, 75)
        XCTAssertEqual(AntigravityQuotaGroups.normalize([report("gemini-pro", 60), report("gemini-flash", 90)]).first?.remainingPercent, 60)
    }

    func testExhaustedPoolPublishesAnExhaustedStatusRatherThanUnknown() throws {
        let groups = AntigravityQuotaGroups.normalize([report("gemini-pro", 54.226995), report("claude-sonnet", 0, period: "weekly")])
        let gemini = try XCTUnwrap(groups.first { $0.id == "antigravity:gemini:5h" })
        let thirdParty = try XCTUnwrap(groups.first { $0.id == "antigravity:third-party:weekly" })
        XCTAssertEqual(gemini.status, .available)
        XCTAssertFalse(gemini.isExhausted)
        // The grouped summary builds its windows without a status; before this
        // the pool below read "unknown" at zero and a consumer would route to it.
        XCTAssertEqual(thirdParty.status, .exhausted)
        XCTAssertTrue(thirdParty.isExhausted)
        XCTAssertTrue(thirdParty.skip)
        XCTAssertEqual(thirdParty.skipReason, "quota exhausted")
    }

    func testPoolsPublishTheirFamilyAsModelTypeSoConsumersCanRoute() {
        let groups = AntigravityQuotaGroups.normalize([report("gemini-pro", 80), report("claude-sonnet", 40)], includeMissing: true)
        XCTAssertEqual(groups.filter { $0.label.hasPrefix("Gemini") }.map(\.modelType), ["gemini", "gemini"])
        XCTAssertEqual(groups.filter { $0.label.hasPrefix("Third-Party") }.map(\.modelType), ["third-party", "third-party"])
        // The family must not re-pool a window into the wrong group on a rerun.
        XCTAssertEqual(AntigravityQuotaGroups.normalize(groups, includeMissing: true), groups)
    }

    private func report(_ model: String, _ percent: Double, period: String? = nil) -> QuotaWindow {
        QuotaWindow(id: model + (period ?? ""), provider: "Antigravity", via: "antigravity", sourceApp: "local-mac",
                    modelId: model, label: model, remainingPercent: percent, resetAt: "2026-09-13T15:00:00Z",
                    window: period, occurredAt: "2026-09-13T10:00:00Z")
    }
}
