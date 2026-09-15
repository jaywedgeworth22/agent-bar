import Foundation
@testable import QuotaCore
import XCTest

final class WindowPacingTests: XCTestCase {
    func testWeeklyPacingUnderCap() {
        let now = Date()
        // Window resets in 2 days; duration is 7 days (so 5 days have elapsed ~ 71.4%)
        let resetAt = now.addingTimeInterval(2 * 86400)
        let remainingPercent = 60.0 // 40% used

        let pacing = WindowPacing.calculate(
            windowToken: "weekly",
            windowLabel: "Weekly limit",
            resetAt: resetAt,
            remainingPercent: remainingPercent,
            now: now
        )

        XCTAssertNotNil(pacing)
        guard let p = pacing else { return }

        XCTAssertEqual(p.durationSeconds, 7 * 86400)
        XCTAssertEqual(p.quotaUsedPercent, 40.0)
        XCTAssertEqual(p.timeElapsedLabel, "Day 5 of 7")
        XCTAssertTrue(p.isUnderCapPace)
        XCTAssertTrue(p.paceDescription.contains("On track"))
        XCTAssertTrue(p.resetLabel.contains("Resets in 2d"))
    }

    func testWeeklyPacingOverCap() {
        let now = Date()
        // Window resets in 5 days; duration is 7 days (so 2 days elapsed ~ 28.5%)
        let resetAt = now.addingTimeInterval(5 * 86400)
        let remainingPercent = 15.0 // 85% used

        let pacing = WindowPacing.calculate(
            windowToken: "7d",
            windowLabel: "7-day window",
            resetAt: resetAt,
            remainingPercent: remainingPercent,
            now: now
        )

        XCTAssertNotNil(pacing)
        guard let p = pacing else { return }

        XCTAssertEqual(p.quotaUsedPercent, 85.0)
        XCTAssertEqual(p.timeElapsedLabel, "Day 2 of 7")
        XCTAssertFalse(p.isUnderCapPace)
        XCTAssertTrue(p.paceDescription.contains("Ahead of pace"))
    }

    func testFiveHourPacing() {
        let now = Date()
        // Resets in 2 hours; duration is 5 hours (so 3 hours have elapsed)
        let resetAt = now.addingTimeInterval(2 * 3600)
        let remainingPercent = 80.0 // 20% used

        let pacing = WindowPacing.calculate(
            windowToken: "5h",
            windowLabel: "5-hour window",
            resetAt: resetAt,
            remainingPercent: remainingPercent,
            now: now
        )

        XCTAssertNotNil(pacing)
        guard let p = pacing else { return }

        XCTAssertEqual(p.durationSeconds, 5 * 3600)
        XCTAssertEqual(p.quotaUsedPercent, 20.0)
        XCTAssertEqual(p.timeElapsedLabel, "3h 0m elapsed")
        XCTAssertTrue(p.isUnderCapPace)
        XCTAssertTrue(p.resetLabel.contains("Resets in 2h"))
    }

    func testDurationParsingTokens() {
        XCTAssertEqual(WindowPacing.parseDurationSeconds(token: "weekly", label: ""), 7 * 86400)
        XCTAssertEqual(WindowPacing.parseDurationSeconds(token: "7d", label: ""), 7 * 86400)
        XCTAssertEqual(WindowPacing.parseDurationSeconds(token: nil, label: "Weekly limit"), 7 * 86400)
        XCTAssertEqual(WindowPacing.parseDurationSeconds(token: "5h", label: ""), 5 * 3600)
        XCTAssertEqual(WindowPacing.parseDurationSeconds(token: "daily", label: ""), 86400)
        XCTAssertEqual(WindowPacing.parseDurationSeconds(token: "monthly", label: ""), 30 * 86400)
        XCTAssertEqual(WindowPacing.parseDurationSeconds(token: "1h", label: ""), 3600)
        XCTAssertNil(WindowPacing.parseDurationSeconds(token: nil, label: "Unknown window"))
    }

    func testPlatformCustomInfoCodable() throws {
        let info = PlatformCustomInfo(
            customSubtitle: "My Pro Plan",
            planName: "Pro Tier",
            costUsd: "$20/mo",
            renewalDateText: "Nov 15",
            showCostAndRenewal: true
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(PlatformCustomInfo.self, from: data)

        XCTAssertEqual(decoded, info)
        XCTAssertEqual(decoded.customSubtitle, "My Pro Plan")
        XCTAssertEqual(decoded.planName, "Pro Tier")
        XCTAssertEqual(decoded.costUsd, "$20/mo")
        XCTAssertEqual(decoded.renewalDateText, "Nov 15")
        XCTAssertTrue(decoded.showCostAndRenewal)
    }
}
