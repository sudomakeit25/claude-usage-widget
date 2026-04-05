import Foundation
import UserNotifications

final class UsageDataService: ObservableObject {
    // Live session data
    @Published var sessions: [StatusLineData] = []
    @Published var lastUpdated: Date = Date()

    // Historical stats
    @Published var summary: UsageSummary = .empty
    @Published var recentSessions: [SessionMeta] = []

    private let claudeDir: String
    private let sessionStatusDir: String
    private let rateLimitsPath: String
    private let statsPath: String
    private let sessionMetaDir: String
    private var refreshTimer: Timer?

    private let staleThreshold: TimeInterval = 24 * 3600

    // Alert thresholds
    private let alertThreshold = 80
    private var fiveHourAlertSent = false
    private var sevenDayAlertSent = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        claudeDir = "\(home)/.claude"
        sessionStatusDir = "\(claudeDir)/session-status"
        rateLimitsPath = "\(claudeDir)/rate-limits.json"
        statsPath = "\(claudeDir)/stats-cache.json"
        sessionMetaDir = "\(claudeDir)/usage-data/session-meta"
        startAutoRefresh()
    }

    func startAutoRefresh(interval: TimeInterval = 5) {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let liveSessions = self.loadAllLiveSessions()
            let stats = self.loadStatsCache()
            let metaSessions = self.loadRecentSessions(limit: 5)
            let summary = self.buildSummary(stats: stats, metaSessions: metaSessions)

            DispatchQueue.main.async {
                self.sessions = liveSessions
                self.summary = summary
                self.recentSessions = metaSessions
                self.lastUpdated = Date()
                self.checkAlerts()
            }
        }
    }

    // Rate limits from the most recently updated session (they're account-level)
    var rateLimits: RateLimits? {
        newestSession?.rateLimits
    }

    // Track which session file was modified most recently
    @Published var newestSession: StatusLineData?

    // MARK: - Live sessions

    private func loadAllLiveSessions() -> [StatusLineData] {
        let fm = FileManager.default
        var results: [(session: StatusLineData, modDate: Date)] = []

        if let files = try? fm.contentsOfDirectory(atPath: sessionStatusDir) {
            let now = Date()
            for file in files where file.hasSuffix(".json") {
                let path = "\(sessionStatusDir)/\(file)"
                let modDate: Date
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let md = attrs[.modificationDate] as? Date {
                    if now.timeIntervalSince(md) > staleThreshold {
                        try? fm.removeItem(atPath: path)
                        continue
                    }
                    modDate = md
                } else {
                    modDate = .distantPast
                }
                guard let data = fm.contents(atPath: path),
                      let session = try? JSONDecoder().decode(StatusLineData.self, from: data) else { continue }
                results.append((session, modDate))
            }
        }

        if results.isEmpty {
            if let data = FileManager.default.contents(atPath: rateLimitsPath),
               let session = try? JSONDecoder().decode(StatusLineData.self, from: data) {
                results.append((session, Date()))
            }
        }

        // Sort by cost for display order
        results.sort { ($0.session.cost?.totalCostUsd ?? 0) > ($1.session.cost?.totalCostUsd ?? 0) }

        // Track the most recently modified session for rate limits
        let newest = results.max(by: { $0.modDate < $1.modDate })?.session
        DispatchQueue.main.async { self.newestSession = newest }

        return results.map { $0.session }
    }

    // MARK: - Stats cache

    private func loadStatsCache() -> StatsCache? {
        guard let data = FileManager.default.contents(atPath: statsPath) else { return nil }
        return try? JSONDecoder().decode(StatsCache.self, from: data)
    }

    // MARK: - Session meta

    private func loadRecentSessions(limit: Int) -> [SessionMeta] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionMetaDir) else { return [] }

        var sessions: [SessionMeta] = []
        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionMetaDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let session = try? JSONDecoder().decode(SessionMeta.self, from: data) else { continue }
            sessions.append(session)
        }
        sessions.sort { $0.startTime > $1.startTime }
        return Array(sessions.prefix(limit))
    }

    // MARK: - Summary

    private func buildSummary(stats: StatsCache?, metaSessions: [SessionMeta]) -> UsageSummary {
        let today = dateString(for: Date())
        let weekAgo = dateString(for: Date().addingTimeInterval(-7 * 86400))
        let twoWeeksAgo = dateString(for: Date().addingTimeInterval(-14 * 86400))

        // From stats-cache (may be stale)
        let todayActivity = stats?.dailyActivity.first { $0.date == today }
        let todayTokenEntry = stats?.dailyModelTokens.first { $0.date == today }
        let statsTodayTokens = todayTokenEntry?.tokensByModel.values.reduce(0, +) ?? 0

        // From session-meta
        let todayMeta = metaSessions.filter { $0.startTime.hasPrefix(today) }
        let metaMessages = todayMeta.reduce(0) { $0 + $1.userMessageCount + $1.assistantMessageCount }
        let metaTokens = todayMeta.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }

        // From live sessions (most current source)
        let liveSessionCount = sessions.count
        let liveTokens = sessions.reduce(0) { total, s in
            let input = s.contextWindow?.totalInputTokens ?? 0
            let output = s.contextWindow?.totalOutputTokens ?? 0
            return total + input + output
        }

        // Count messages and tools from active session transcripts
        var liveMessages = 0
        var liveToolCalls = 0
        for session in sessions {
            if let sessionId = session.sessionId {
                let counts = countMessagesInTranscript(sessionId: sessionId)
                liveMessages += counts.messages
                liveToolCalls += counts.toolCalls
            }
        }

        // Week stats from stats-cache
        let weekActivities = stats?.dailyActivity.filter { $0.date >= weekAgo } ?? []
        let weekTokenEntries = stats?.dailyModelTokens.filter { $0.date >= weekAgo } ?? []
        let statsWeekMessages = weekActivities.reduce(0) { $0 + $1.messageCount }
        let statsWeekSessions = weekActivities.reduce(0) { $0 + $1.sessionCount }
        let statsWeekTokens = weekTokenEntries.reduce(0) { $0 + $1.tokensByModel.values.reduce(0, +) }

        // Use the best available data (live > meta > stats-cache)
        let bestTodaySessions = max(todayActivity?.sessionCount ?? 0, max(todayMeta.count, liveSessionCount))
        let bestTodayTokens = max(statsTodayTokens, max(metaTokens, liveTokens))

        let bestTodayMessages = max(todayActivity?.messageCount ?? 0, max(metaMessages, liveMessages))
        let bestTodayToolCalls = max(todayActivity?.toolCallCount ?? 0, liveToolCalls)

        return UsageSummary(
            todayMessages: bestTodayMessages,
            todaySessions: bestTodaySessions,
            todayToolCalls: bestTodayToolCalls,
            todayTokens: bestTodayTokens,
            weekMessages: max(statsWeekMessages, bestTodayMessages),
            weekSessions: max(statsWeekSessions, bestTodaySessions),
            weekTokens: max(statsWeekTokens, bestTodayTokens),
            recentDays: stats?.dailyActivity.filter { $0.date >= twoWeeksAgo } ?? [],
            modelBreakdown: stats?.modelUsage ?? [:]
        )
    }

    private func countMessagesInTranscript(sessionId: String) -> (messages: Int, toolCalls: Int) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let projectsDir = "\(home)/.claude/projects"

        // Find the transcript file
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return (0, 0) }
        for dir in dirs {
            let path = "\(projectsDir)/\(dir)/\(sessionId).jsonl"
            guard let data = fm.contents(atPath: path),
                  let content = String(data: data, encoding: .utf8) else { continue }

            var messages = 0
            var toolCalls = 0
            for line in content.components(separatedBy: .newlines) where !line.isEmpty {
                if line.contains("\"type\":\"user\"") && !line.contains("\"tool_result\"") {
                    messages += 1
                } else if line.contains("\"type\":\"assistant\"") {
                    messages += 1
                    // Count tool_use blocks
                    let toolCount = line.components(separatedBy: "\"type\":\"tool_use\"").count - 1
                    toolCalls += toolCount
                }
            }
            return (messages, toolCalls)
        }
        return (0, 0)
    }

    private func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Alerts

    private func checkAlerts() {
        guard let limits = rateLimits else { return }

        // 5-hour window alert
        if limits.fiveHour.effectivePercentage >= alertThreshold && !fiveHourAlertSent {
            fiveHourAlertSent = true
            sendNotification(
                title: "Claude Usage: 5-Hour Limit",
                body: "\(limits.fiveHour.effectivePercentage)% used. Resets in \(limits.fiveHour.timeUntilReset)."
            )
        } else if limits.fiveHour.effectivePercentage < alertThreshold {
            fiveHourAlertSent = false
        }

        // 7-day window alert
        if limits.sevenDay.effectivePercentage >= alertThreshold && !sevenDayAlertSent {
            sevenDayAlertSent = true
            sendNotification(
                title: "Claude Usage: 7-Day Limit",
                body: "\(limits.sevenDay.effectivePercentage)% used. Resets \(limits.sevenDay.timeUntilReset)."
            )
        } else if limits.sevenDay.effectivePercentage < alertThreshold {
            sevenDayAlertSent = false
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
