import XCTest
@testable import QuotaCore

/// Fixtures mirror a live `GET /api/quota-windows` response: every window
/// carries `source` and `sourceApp`, and no host, producer or device field.
/// This Mac's own push comes back with the producer id the publisher sends.
final class FleetOriginTests: XCTestCase {
    func testIdentityPrefersSourceAndFallsBackInOrder() {
        XCTAssertEqual(FleetOrigin.identity(of: window(source: "antigravity-usage", sourceApp: "antigravity-cli")),
                       "antigravity-usage")
        XCTAssertEqual(FleetOrigin.identity(of: window(source: "  ", sourceApp: "antigravity-cli")),
                       "antigravity-cli")
        XCTAssertEqual(FleetOrigin.identity(of: window(source: nil, sourceApp: nil)), "fleet")
    }

    func testOwnPushIsRecognisedByProducerIdOrHostName() {
        XCTAssertTrue(FleetOrigin.isOwnPush(window(source: "agent-bar", sourceApp: "agent-bar"), host: "Studio"))
        XCTAssertTrue(FleetOrigin.isOwnPush(window(source: "Studio", sourceApp: nil), host: "Studio"))
        XCTAssertTrue(FleetOrigin.isOwnPush(window(source: "studio", sourceApp: nil), host: "Studio.local"))
        XCTAssertFalse(FleetOrigin.isOwnPush(window(source: "antigravity-usage", sourceApp: "antigravity-cli"),
                                             host: "Studio"))
        XCTAssertEqual(QuotaPublisher.producerId, "agent-bar")
    }

    func testEveryWindowSurvivesTheSplitAndIsGroupedByOrigin() {
        // The shape of the live payload: this Mac's push echoed back, plus a
        // second producer's own reading of the same provider.
        let windows = [
            window(id: "anthropic-five_hour", source: "agent-bar", sourceApp: "agent-bar"),
            window(id: "gemini-weekly", source: "agent-bar", sourceApp: "agent-bar"),
            window(id: "claude-sonnet-4-6", source: "antigravity-usage", sourceApp: "antigravity-cli"),
            window(id: "gemini-3-flash", source: "antigravity-usage", sourceApp: "antigravity-cli"),
            window(id: "grok-bot-weekly", source: "other-mac", sourceApp: "agent-bar"),
        ]
        let split = FleetOrigin.split(windows, host: "Studio")
        XCTAssertEqual(split.ownPush.map(\.id), ["anthropic-five_hour", "gemini-weekly"])
        XCTAssertEqual(split.groups.map(\.id), ["antigravity-usage", "other-mac"])
        XCTAssertEqual(split.groups.map(\.title), ["Antigravity Usage", "Other Mac"])
        XCTAssertEqual(split.groups.map { $0.windows.count }, [2, 1])
        // Nothing is dropped: the old supplemental filter discarded every
        // pulled window whose provider this Mac also reads locally.
        XCTAssertEqual(split.ownPush.count + split.groups.reduce(0) { $0 + $1.windows.count }, windows.count)
    }

    func testTitleReadsAsAName() {
        XCTAssertEqual(FleetOrigin.title(for: "antigravity-usage"), "Antigravity Usage")
        XCTAssertEqual(FleetOrigin.title(for: "agent_bar"), "Agent Bar")
        XCTAssertEqual(FleetOrigin.title(for: "Studio"), "Studio")
        XCTAssertEqual(FleetOrigin.title(for: "fleet"), "Fleet")
    }

    private func window(id: String = "w", source: String?, sourceApp: String?) -> QuotaWindow {
        QuotaWindow(id: id, provider: "anthropic", providerKey: "anthropic", sourceApp: sourceApp,
                    label: "5h window", remainingPercent: 50,
                    occurredAt: "2026-09-17T03:37:53.456Z", source: source)
    }
}
