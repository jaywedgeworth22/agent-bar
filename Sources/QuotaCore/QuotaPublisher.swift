import Foundation

public enum QuotaSyncFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case usageMonitorV2 = "usage_monitor_v2"
    case genericWebhook = "generic_webhook"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .usageMonitorV2: return "Usage Monitor (v2 Ingest)"
        case .genericWebhook: return "Standard JSON Webhook"
        }
    }
}

public struct QuotaPublishResult: Sendable, Equatable {
    public let statusCode: Int
    public let count: Int
    public let message: String

    public init(statusCode: Int, count: Int, message: String) {
        self.statusCode = statusCode
        self.count = count
        self.message = message
    }
}

public enum QuotaPublisherError: Error, Equatable, Sendable, LocalizedError {
    case invalidEndpoint
    case emptyWindows
    case unauthorized
    case httpStatus(Int, String?)
    case timedOut
    case transport(String)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The sync endpoint URL is invalid or not allowed (must be HTTPS or localhost)."
        case .emptyWindows:
            return "No quota windows to publish."
        case .unauthorized:
            return "Unauthorized (HTTP 401). Check your Ingest Token."
        case let .httpStatus(status, detail):
            if let detail, !detail.isEmpty {
                return "Server returned HTTP \(status): \(detail)"
            }
            return "Server returned HTTP \(status)."
        case .timedOut:
            return "The sync request timed out (10s)."
        case let .transport(msg):
            return "Network error: \(msg)"
        case let .serverError(msg):
            return "Server error: \(msg)"
        }
    }
}

public actor QuotaPublisher {
    private let timeout: TimeInterval
    private let session: URLSession

    public init(timeout: TimeInterval = 10, urlProtocolClasses: [AnyClass]? = nil) {
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        if let urlProtocolClasses { config.protocolClasses = urlProtocolClasses }
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func publish(
        windows: [QuotaWindow],
        to endpoint: URL,
        token: String? = nil,
        format: QuotaSyncFormat = .usageMonitorV2,
        machineName: String? = nil
    ) async throws -> QuotaPublishResult {
        guard QuotaClient.isAllowedEndpoint(endpoint) else {
            throw QuotaPublisherError.invalidEndpoint
        }
        guard !windows.isEmpty else {
            throw QuotaPublisherError.emptyWindows
        }

        let bodyData: Data
        let now = Date()
        let occurredAtIso = ISO8601DateFormatter().string(from: now)

        switch format {
        case .usageMonitorV2:
            bodyData = try buildUsageMonitorV2Payload(windows: windows, occurredAtIso: occurredAtIso)
        case .genericWebhook:
            bodyData = try buildGenericWebhookPayload(windows: windows, occurredAtIso: occurredAtIso, machineName: machineName)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2", forHTTPHeaderField: "x-usage-telemetry-version")
        request.setValue("agent-bar/1.0", forHTTPHeaderField: "User-Agent")

        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "x-usage-ingest-token")
        }

        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw QuotaPublisherError.transport("Invalid response type")
            }

            if (200..<300).contains(http.statusCode) {
                var message = "Pushed \(windows.count) quota windows successfully."
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let persisted = json["persisted"] as? Int, let received = json["received"] as? Int {
                        message = "Synced \(received) quotas (\(persisted) persisted)."
                    } else if let ok = json["ok"] as? Bool, ok {
                        message = "Synced \(windows.count) quotas (200 OK)."
                    }
                }
                return QuotaPublishResult(statusCode: http.statusCode, count: windows.count, message: message)
            } else if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaPublisherError.unauthorized
            } else {
                let detail = String(data: data.prefix(512), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw QuotaPublisherError.httpStatus(http.statusCode, detail)
            }
        } catch let err as QuotaPublisherError {
            throw err
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlErr as URLError where urlErr.code == .timedOut {
            throw QuotaPublisherError.timedOut
        } catch {
            throw QuotaPublisherError.transport(error.localizedDescription)
        }
    }

    public nonisolated func buildUsageMonitorV2Payload(windows: [QuotaWindow], occurredAtIso: String, machineName: String? = nil) throws -> Data {
        let machine = machineName ?? Host.current().localizedName ?? "Mac"
        let events: [[String: Any]] = windows.compactMap { window in
            guard let remaining = window.boundedRemainingPercent ?? window.remainingPercent else { return nil }
            let seriesKey = window.resetAt ?? "\(occurredAtIso.prefix(13)):00"
            let bucketId: String = {
                if let modelId = window.modelId, !modelId.isEmpty {
                    return "\(modelId)-\(window.window ?? "window")"
                }
                if !window.id.isEmpty && window.id.contains(":") {
                    let parts = window.id.split(separator: ":").map(String.init)
                    if parts.count >= 2 {
                        return parts.dropFirst().joined(separator: "-")
                    }
                }
                return window.window ?? window.label.lowercased().replacingOccurrences(of: " ", with: "-")
            }()
            let readingTime = window.occurredAt.isEmpty ? occurredAtIso : window.occurredAt
            let eventId = "subq:\(window.canonicalProviderKey):\(bucketId):\(seriesKey):\(readingTime)"
            let clampedRemaining = round(remaining * 100.0) / 100.0
            let usedPercent = round(max(0, min(100, 100.0 - clampedRemaining)) * 100.0) / 100.0

            var meta: [String: Any] = [
                "bucketId": bucketId,
                "isExhausted": window.isExhausted || clampedRemaining <= 0,
                "remainingUnknown": false,
                "scale": "percent_0_100",
                "source": "agent-bar"
            ]
            if let resetAt = window.resetAt { meta["resetAt"] = resetAt }
            if let w = window.window { meta["quotaWindow"] = w }
            if let modelId = window.modelId { meta["modelId"] = modelId }
            if let plan = window.planName { meta["planType"] = plan }
            meta["usedPercent"] = usedPercent

            var event: [String: Any] = [
                "eventId": eventId,
                "provider": window.canonicalProviderKey,
                "service": "agent-bar",
                "label": window.label,
                "metricType": "quota",
                "billingMode": "actual",
                "confidence": "actual",
                "limit": 100,
                "credits": clampedRemaining,
                "occurredAt": readingTime,
                "metadata": meta
            ]
            if let plan = window.planName { event["tier"] = plan }
            return event
        }

        let root: [String: Any] = [
            "schemaVersion": 2,
            "producerId": "agent-bar",
            "producerInstanceId": machine,
            "events": events
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    public nonisolated func buildGenericWebhookPayload(windows: [QuotaWindow], occurredAtIso: String, machineName: String?) throws -> Data {
        let machine = machineName ?? Host.current().localizedName ?? "Mac"
        let windowPayloads: [[String: Any]] = windows.map { w in
            var dict: [String: Any] = [
                "id": w.id,
                "provider": w.provider,
                "label": w.label,
                "status": w.status.rawValue,
                "isExhausted": w.isExhausted
            ]
            if let rem = w.remainingPercent { dict["remainingPercent"] = rem }
            if let reset = w.resetAt { dict["resetAt"] = reset }
            if let win = w.window { dict["window"] = win }
            if let plan = w.planName { dict["plan"] = plan }
            dict["occurredAt"] = w.occurredAt
            return dict
        }

        let root: [String: Any] = [
            "format": "agent-bar-quotas",
            "version": 1,
            "generatedAt": occurredAtIso,
            "machine": machine,
            "count": windows.count,
            "windows": windowPayloads
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
