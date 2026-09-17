import XCTest
@testable import QuotaCore

/// The order of the two steps on the pull path matters, and getting it wrong is
/// invisible until a second producer reports the same provider.
final class FleetPipelineTests: XCTestCase {
    /// A trimmed copy of a live `GET /api/quota-windows` body: this Mac's pushed
    /// pool windows, and another producer's per-model Antigravity readings.
    private let body = """
    {"generatedAt":"2026-09-17T03:37:53.456Z","windows":[
      {"id":"gemini-weekly","provider":"google-antigravity","providerKey":"google-antigravity","via":"antigravity","sourceApp":"agent-bar","source":"agent-bar","modelType":"gemini","label":"Gemini Models · Weekly","remainingPercent":88.66,"window":"weekly","occurredAt":"2026-09-17T03:37:00.000Z"},
      {"id":"third-party-weekly","provider":"google-antigravity","providerKey":"google-antigravity","via":"antigravity","sourceApp":"agent-bar","source":"agent-bar","modelType":"third-party","label":"Third-Party Models · Weekly","remainingPercent":0,"window":"weekly","occurredAt":"2026-09-17T03:37:00.000Z"},
      {"id":"claude-sonnet-4-6","provider":"google-antigravity","providerKey":"google-antigravity","via":"antigravity","sourceApp":"antigravity-cli","source":"antigravity-usage","label":"Claude Sonnet 4.6 (Thinking)","remainingPercent":0,"window":"weekly","occurredAt":"2026-09-17T03:30:00.000Z"},
      {"id":"gemini-3-flash","provider":"google-antigravity","providerKey":"google-antigravity","via":"antigravity","sourceApp":"antigravity-cli","source":"antigravity-usage","label":"Gemini 3 Flash","remainingPercent":100,"window":"5h","occurredAt":"2026-09-17T03:30:00.000Z"},
      {"id":"anthropic-five_hour","provider":"anthropic","providerKey":"anthropic","sourceApp":"agent-bar","source":"agent-bar","label":"5h window","remainingPercent":85,"window":"5h","occurredAt":"2026-09-17T03:37:00.000Z"}
    ]}
    """

    private func decoded() throws -> QuotaResponse {
        try JSONDecoder().decode(QuotaResponse.self, from: Data(body.utf8))
    }

    func testSplittingBeforeSectioningKeepsTheSecondProducer() throws {
        let response = try decoded()
        let split = FleetOrigin.split(response.windows, host: "Studio")
        XCTAssertEqual(split.ownPush.count, 3)
        XCTAssertEqual(split.groups.map(\.title), ["Antigravity Usage"])
        XCTAssertEqual(split.groups.first?.windows.count, 2)

        // The group is sectioned on its own, so its readings become that
        // machine's Antigravity rows rather than being folded into this Mac's.
        let sections = QuotaResponse(generatedAt: "", windows: split.groups[0].windows)
            .platformSections(now: ISO8601DateFormatter().date(from: "2026-09-17T03:35:00Z")!)
            .filter { !$0.windows.isEmpty }
        XCTAssertEqual(sections.map(\.providerKey), ["google-antigravity"])
        XCTAssertFalse(sections[0].windows.isEmpty)
    }

    func testSectioningFirstWouldHaveErasedTheOrigin() throws {
        let response = try decoded()
        // This is what the pull path used to do before splitting: pooling runs,
        // four Antigravity windows come out, and only the winning observation's
        // origin survives — so the second producer disappeared before anything
        // could group it.  The assertion documents why the order is fixed.
        let pooled = response.platformSections(now: Date())
            .flatMap { $0.windows.map(\.window) }
            .filter { $0.canonicalProviderKey == "google-antigravity" }
        XCTAssertEqual(pooled.count, 4)
        // Every per-model reading is gone, replaced by the two pools' windows,
        // and each surviving window carries just one observation's origin.
        XCTAssertFalse(pooled.contains { $0.label == "Gemini 3 Flash" })
        XCTAssertTrue(pooled.allSatisfy { $0.label.contains("Models · ") })
        // Whichever observation wins a pool lends it its origin, so one
        // platform's four pooled windows carry two different machines between
        // them and could not be filed under either honestly.
        XCTAssertEqual(Set(pooled.map { FleetOrigin.identity(of: $0) }),
                       ["agent-bar", "antigravity-usage", "fleet"])
    }
}
