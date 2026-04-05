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

    var rateLimits: RateLimits? {
        sessions.first?.rateLimits
    }

    // MARK: - Live sessions

    private func loadAllLiveSessions() -> [StatusLineData] {
        let fm = FileManager.default
        var results: [StatusLineData] = []

        if let files = try? fm.contentsOfDirectory(atPath: sessionStatusDir) {
            let now = Date()
            for file in files where file.hasSuffix(".json") {
                let path = "\(sessionStatusDir)/\(file)"
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let modDate = attrs[.modificationDate] as? Date,
                   now.timeIntervalSince(modDate) > staleThreshold {
                    try? fm.removeItem(atPath: path)
                    continue
                }
                guard let data = fm.contents(atPath: path),
                      let session = try? JSONDecoder().decode(StatusLineData.self, from: data) else { continue }
                results.append(session)
            }
        }

        if results.isEmpty {
            if let data = FileManager.default.contents(atPath: rateLimitsPath),
               let session = try? JSONDecoder().decode(StatusLineData.self, from: data) {
                results.append(session)
            }
        }

        results.sort { ($0.cost?.totalCostUsd ?? 0) > ($1.cost?.totalCostUsd ?? 0) }
        return results
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

        // Week stats from stats-cache
        let weekActivities = stats?.dailyActivity.filter { $0.date >= weekAgo } ?? []
        let weekTokenEntries = stats?.dailyModelTokens.filter { $0.date >= weekAgo } ?? []
        let statsWeekMessages = weekActivities.reduce(0) { $0 + $1.messageCount }
        let statsWeekSessions = weekActivities.reduce(0) { $0 + $1.sessionCount }
        let statsWeekTokens = weekTokenEntries.reduce(0) { $0 + $1.tokensByModel.values.reduce(0, +) }

        // Use the best available data (live > meta > stats-cache)
        let bestTodaySessions = max(todayActivity?.sessionCount ?? 0, max(todayMeta.count, liveSessionCount))
        let bestTodayTokens = max(statsTodayTokens, max(metaTokens, liveTokens))

        return UsageSummary(
            todayMessages: max(todayActivity?.messageCount ?? 0, metaMessages),
            todaySessions: bestTodaySessions,
            todayToolCalls: todayActivity?.toolCallCount ?? 0,
            todayTokens: bestTodayTokens,
            weekMessages: max(statsWeekMessages, metaMessages),
            weekSessions: max(statsWeekSessions, bestTodaySessions),
            weekTokens: max(statsWeekTokens, bestTodayTokens),
            recentDays: stats?.dailyActivity.filter { $0.date >= twoWeeksAgo } ?? [],
            modelBreakdown: stats?.modelUsage ?? [:]
        )
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
