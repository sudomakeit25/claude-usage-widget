import Foundation

// MARK: - Statusline data (from ~/.claude/rate-limits.json)

struct StatusLineData: Codable {
    let sessionId: String?
    let cwd: String?
    let model: ModelInfo?
    let cost: CostInfo?
    let contextWindow: ContextWindow?
    let rateLimits: RateLimits?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case model
        case cost
        case contextWindow = "context_window"
        case rateLimits = "rate_limits"
        case version
    }
}

struct ModelInfo: Codable {
    let id: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct CostInfo: Codable {
    let totalCostUsd: Double
    let totalDurationMs: Int?
    let totalApiDurationMs: Int?
    let totalLinesAdded: Int?
    let totalLinesRemoved: Int?

    enum CodingKeys: String, CodingKey {
        case totalCostUsd = "total_cost_usd"
        case totalDurationMs = "total_duration_ms"
        case totalApiDurationMs = "total_api_duration_ms"
        case totalLinesAdded = "total_lines_added"
        case totalLinesRemoved = "total_lines_removed"
    }
}

struct ContextWindow: Codable {
    let totalInputTokens: Int?
    let totalOutputTokens: Int?
    let contextWindowSize: Int?
    let usedPercentage: Int
    let remainingPercentage: Int

    enum CodingKeys: String, CodingKey {
        case totalInputTokens = "total_input_tokens"
        case totalOutputTokens = "total_output_tokens"
        case contextWindowSize = "context_window_size"
        case usedPercentage = "used_percentage"
        case remainingPercentage = "remaining_percentage"
    }
}

struct RateLimits: Codable {
    let fiveHour: RateWindow
    let sevenDay: RateWindow

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct RateWindow: Codable {
    let usedPercentage: Int
    let resetsAt: Int

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    var resetDate: Date {
        Date(timeIntervalSince1970: TimeInterval(resetsAt))
    }

    /// If the reset time has passed, the limit has already reset
    var hasReset: Bool {
        Date() >= resetDate
    }

    /// Effective percentage, accounting for resets that already happened
    var effectivePercentage: Int {
        hasReset ? 0 : usedPercentage
    }

    var timeUntilReset: String {
        let now = Date()
        let reset = resetDate
        guard reset > now else { return "Reset" }

        let diff = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: reset)
        if let d = diff.day, d > 0 {
            let dayName = dayOfWeek(reset)
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "\(dayName) \(formatter.string(from: reset))"
        }
        if let h = diff.hour, let m = diff.minute {
            if h > 0 {
                return "\(h) hr \(m) min"
            }
            return "\(m) min"
        }
        return "soon"
    }

    private func dayOfWeek(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}

// MARK: - Stats Cache (from ~/.claude/stats-cache.json)

struct StatsCache: Codable {
    let version: Int
    let lastComputedDate: String
    let dailyActivity: [DailyActivity]
    let dailyModelTokens: [DailyModelTokens]
    let modelUsage: [String: ModelUsage]
    let totalSessions: Int
    let totalMessages: Int
    let longestSession: LongestSession?
    let firstSessionDate: String?
    let hourCounts: [String: Int]?
}

struct DailyActivity: Codable, Identifiable {
    var id: String { date }
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

struct DailyModelTokens: Codable {
    let date: String
    let tokensByModel: [String: Int]
}

struct ModelUsage: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let webSearchRequests: Int
    let costUSD: Double
}

struct LongestSession: Codable {
    let sessionId: String
    let duration: Int
    let messageCount: Int
    let timestamp: String
}

// MARK: - Session Meta (per-session files)

struct SessionMeta: Codable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let projectPath: String?
    let startTime: String
    let durationMinutes: Int?
    let userMessageCount: Int
    let assistantMessageCount: Int
    let toolCounts: [String: Int]?
    let inputTokens: Int
    let outputTokens: Int
    let firstPrompt: String?
    let linesAdded: Int?
    let linesRemoved: Int?
    let filesModified: Int?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case projectPath = "project_path"
        case startTime = "start_time"
        case durationMinutes = "duration_minutes"
        case userMessageCount = "user_message_count"
        case assistantMessageCount = "assistant_message_count"
        case toolCounts = "tool_counts"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case firstPrompt = "first_prompt"
        case linesAdded = "lines_added"
        case linesRemoved = "lines_removed"
        case filesModified = "files_modified"
    }
}

// MARK: - Computed summary

struct UsageSummary {
    let todayMessages: Int
    let todaySessions: Int
    let todayToolCalls: Int
    let todayTokens: Int
    let weekMessages: Int
    let weekSessions: Int
    let weekTokens: Int
    let recentDays: [DailyActivity]
    let modelBreakdown: [String: ModelUsage]
}

extension UsageSummary {
    static let empty = UsageSummary(
        todayMessages: 0, todaySessions: 0, todayToolCalls: 0, todayTokens: 0,
        weekMessages: 0, weekSessions: 0, weekTokens: 0,
        recentDays: [], modelBreakdown: [:]
    )
}
