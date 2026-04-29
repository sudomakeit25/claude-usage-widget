import Foundation

// Polls Anthropic for fresh rate-limit data when the local statusline file
// has gone stale. Approach lifted from rjwalters/claude-monitor: make a
// near-zero-cost messages.create call (Haiku, max_tokens=1) and parse the
// anthropic-ratelimit-unified-* headers from the response. Both 200 and 429
// responses include the headers, so even a rate-limited account gets data.

struct PolledRateLimits {
    let fiveHourPercent: Double      // 0–100
    let fiveHourResetsAt: Date?
    let sevenDayPercent: Double      // 0–100
    let sevenDayResetsAt: Date?
    let polledAt: Date

    // Convert to the local RateLimits shape so the existing UI can render it.
    // The API may return a `resets_at` in the past when the user is between
    // bursts — but the utilization figure is still the live ground truth. To
    // prevent the existing `hasReset` logic from zeroing out real usage, we
    // bump any past `resets_at` to a sensible future time (now + window length).
    func toRateLimits() -> RateLimits {
        let now = Date().timeIntervalSince1970
        let fiveHourFallback = now + 5 * 3600
        let sevenDayFallback = now + 7 * 86400
        let fiveHourReset = fiveHourResetsAt.map { $0.timeIntervalSince1970 } ?? fiveHourFallback
        let sevenDayReset = sevenDayResetsAt.map { $0.timeIntervalSince1970 } ?? sevenDayFallback
        return RateLimits(
            fiveHour: RateWindow(
                usedPercentage: fiveHourPercent,
                resetsAt: Int(max(fiveHourReset, fiveHourFallback))
            ),
            sevenDay: RateWindow(
                usedPercentage: sevenDayPercent,
                resetsAt: Int(max(sevenDayReset, sevenDayFallback))
            )
        )
    }
}

enum AnthropicAPIError: Error {
    case unauthorized
    case httpError(Int)
    case invalidResponse
    case network(Error)
}

final class AnthropicAPIClient {
    private let session = URLSession.shared

    func pingForRateLimits(accessToken: String) async throws -> PolledRateLimits {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.0.37", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"x"}]}"#
            .data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnthropicAPIError.network(error)
        }
        _ = data

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicAPIError.invalidResponse
        }

        if http.statusCode == 401 { throw AnthropicAPIError.unauthorized }
        guard http.statusCode == 200 || http.statusCode == 429 else {
            throw AnthropicAPIError.httpError(http.statusCode)
        }

        let h = http.allHeaderFields

        return PolledRateLimits(
            fiveHourPercent: (parseDouble(h["anthropic-ratelimit-unified-5h-utilization"]) ?? 0) * 100,
            fiveHourResetsAt: parseEpoch(h["anthropic-ratelimit-unified-5h-reset"]),
            sevenDayPercent: (parseDouble(h["anthropic-ratelimit-unified-7d-utilization"]) ?? 0) * 100,
            sevenDayResetsAt: parseEpoch(h["anthropic-ratelimit-unified-7d-reset"]),
            polledAt: Date()
        )
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let s = value as? String { return Double(s) }
        if let d = value as? Double { return d }
        return nil
    }

    private func parseEpoch(_ value: Any?) -> Date? {
        guard let s = value as? String, let n = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: n)
    }
}
