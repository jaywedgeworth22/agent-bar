import Foundation
@testable import QuotaCore
import XCTest

private final class MockSyncProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockSyncProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class QuotaPublisherTests: XCTestCase {
    override func tearDown() {
        MockSyncProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeSampleWindows() -> [QuotaWindow] {
        [
            QuotaWindow(
                id: "anthropic-5h",
                provider: "anthropic",
                providerKey: "anthropic",
                providerLabel: "Anthropic",
                via: nil,
                sourceApp: nil,
                modelId: nil,
                modelType: nil,
                label: "Claude 5h",
                remainingPercent: 85.0,
                absoluteRemaining: nil,
                absoluteLimit: nil,
                quotaUnit: nil,
                planName: "Claude Max",
                remainingUnknown: false,
                isExhausted: false,
                resetAt: "2026-09-14T22:00:00Z",
                window: "5h",
                status: .available,
                skip: false,
                skipReason: nil,
                occurredAt: "2026-09-14T19:00:00Z",
                source: "local"
            ),
            QuotaWindow(
                id: "codex-weekly",
                provider: "openai",
                providerKey: "openai",
                providerLabel: "OpenAI",
                via: nil,
                sourceApp: nil,
                modelId: nil,
                modelType: nil,
                label: "Codex Weekly",
                remainingPercent: 12.0,
                absoluteRemaining: nil,
                absoluteLimit: nil,
                quotaUnit: nil,
                planName: nil,
                remainingUnknown: false,
                isExhausted: false,
                resetAt: "2026-09-15T00:00:00Z",
                window: "weekly",
                status: .nearCap,
                skip: false,
                skipReason: nil,
                occurredAt: "2026-09-14T19:00:00Z",
                source: "local"
            )
        ]
    }

    func testBuildUsageMonitorV2Payload() throws {
        let publisher = QuotaPublisher()
        let windows = makeSampleWindows()
        let data = try publisher.buildUsageMonitorV2Payload(windows: windows, occurredAtIso: "2026-09-14T19:00:00Z")
        
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)

        let first = events[0]
        XCTAssertEqual(first["provider"] as? String, "anthropic")
        XCTAssertEqual(first["service"] as? String, "agent-bar")
        XCTAssertEqual(first["label"] as? String, "Claude 5h")
        XCTAssertEqual(first["metricType"] as? String, "quota")
        XCTAssertEqual(first["limit"] as? Int, 100)
        XCTAssertEqual(first["credits"] as? Double, 85.0)
        XCTAssertEqual(first["tier"] as? String, "Claude Max")

        let meta = try XCTUnwrap(first["metadata"] as? [String: Any])
        XCTAssertEqual(meta["remainingPercent"] as? Double, 85.0)
        XCTAssertEqual(meta["quotaWindow"] as? String, "5h")
        XCTAssertEqual(meta["resetAt"] as? String, "2026-09-14T22:00:00Z")
        XCTAssertEqual(meta["source"] as? String, "agent-bar")
    }

    func testBuildGenericWebhookPayload() throws {
        let publisher = QuotaPublisher()
        let windows = makeSampleWindows()
        let data = try publisher.buildGenericWebhookPayload(windows: windows, occurredAtIso: "2026-09-14T19:00:00Z", machineName: "Test-MacBook")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "agent-bar-quotas")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["machine"] as? String, "Test-MacBook")
        XCTAssertEqual(json["count"] as? Int, 2)

        let list = try XCTUnwrap(json["windows"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["label"] as? String, "Claude 5h")
        XCTAssertEqual(list[0]["remainingPercent"] as? Double, 85.0)
        XCTAssertEqual(list[1]["status"] as? String, "near_cap")
    }

    func testPublishRequiresAllowedEndpoint() async {
        let publisher = QuotaPublisher()
        let windows = makeSampleWindows()
        let invalidUrl = URL(string: "ftp://example.com/api")!

        do {
            _ = try await publisher.publish(windows: windows, to: invalidUrl)
            XCTFail("Expected invalidEndpoint error")
        } catch let err as QuotaPublisherError {
            XCTAssertEqual(err, .invalidEndpoint)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPublishEmptyWindowsFailsFast() async {
        let publisher = QuotaPublisher()
        let url = URL(string: "https://usage.example.com/api/ingest/usage")!

        do {
            _ = try await publisher.publish(windows: [], to: url)
            XCTFail("Expected emptyWindows error")
        } catch let err as QuotaPublisherError {
            XCTAssertEqual(err, .emptyWindows)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPublishHandlesSuccess() async throws {
        MockSyncProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-ingest-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-usage-ingest-token"), "test-ingest-token")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            let responseData = "{\"received\": 2, \"persisted\": 2}".data(using: .utf8)!
            return (response, responseData)
        }

        let publisher = QuotaPublisher(urlProtocolClasses: [MockSyncProtocol.self])
        let windows = makeSampleWindows()
        let url = URL(string: "https://usage.jays.services/api/ingest/usage")!

        let result = try await publisher.publish(windows: windows, to: url, token: "test-ingest-token")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.message.contains("Synced 2 quotas (2 persisted)"))
    }

    func testPublishHandlesUnauthorized() async {
        MockSyncProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let publisher = QuotaPublisher(urlProtocolClasses: [MockSyncProtocol.self])
        let windows = makeSampleWindows()
        let url = URL(string: "https://usage.jays.services/api/ingest/usage")!

        do {
            _ = try await publisher.publish(windows: windows, to: url, token: "bad-token")
            XCTFail("Expected unauthorized error")
        } catch let err as QuotaPublisherError {
            XCTAssertEqual(err, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
