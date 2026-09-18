import XCTest
@testable import QuotaCore

final class BillingRenewalTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let timeZone = TimeZone(secondsFromGMT: 0)!
    private let now = ISO8601DateFormatter().date(from: "2026-09-18T12:00:00Z")!

    func testBillingCycleEndBecomesAShortDate() {
        let text = BillingRenewal.text(
            for: [window(token: "billing-cycle", resetAt: "2026-10-17T18:32:00Z")],
            now: now,
            locale: locale,
            timeZone: timeZone
        )
        XCTAssertEqual(text, "Oct 17")
    }

    func testAQuotaResetIsNotAPlanRenewal() {
        let text = BillingRenewal.text(
            for: [window(token: "5h", resetAt: "2026-10-17T18:32:00Z")],
            now: now,
            locale: locale,
            timeZone: timeZone
        )
        XCTAssertNil(text)
    }

    func testTheNextFutureCycleWinsOverAnOlderOne() {
        let text = BillingRenewal.text(
            for: [
                window(token: "billing-cycle", resetAt: "2026-09-17T18:32:00Z"),
                window(token: "billing-cycle", resetAt: "2026-10-17T18:32:00Z"),
            ],
            now: now,
            locale: locale,
            timeZone: timeZone
        )
        XCTAssertEqual(text, "Oct 17")
    }

    private func window(token: String, resetAt: String) -> QuotaWindow {
        QuotaWindow(
            id: "local-mac:cursor:plan",
            provider: "Cursor",
            label: "Included plan",
            resetAt: resetAt,
            window: token,
            occurredAt: "2026-09-18T09:00:00Z"
        )
    }
}
