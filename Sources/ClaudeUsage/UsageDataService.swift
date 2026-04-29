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

    // Alert thresholds — two-tier (warning + critical)
    private let warningThreshold = 60
    private let criticalThreshold = 80

    private enum AlertLevel: Int { case none = 0, warning = 1, critical = 2 }
    private var fiveHourAlertLevel: AlertLevel = .none
    private var sevenDayAlertLevel: AlertLevel = .none

    // Polled rate-limit data from Anthropic's API (fallback when statusline is stale)
    @Published var polledRateLimits: PolledRateLimits?
    private let apiClient = AnthropicAPIClient()
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 5 * 60   // 5 minutes

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        claudeDir = "\(home)/.claude"
        sessionStatusDir = "\(claudeDir)/session-status"
        rateLimitsPath = "\(claudeDir)/rate-limits.json"
        statsPath = "\(claudeDir)/stats-cache.json"
        sessionMetaDir = "\(claudeDir)/usage-data/session-meta"
        startAutoRefresh()
        startRateLimitPolling()
    }

    func startAutoRefresh(interval: TimeInterval = 5) {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Rate-limit polling (Anthropic API)

    func startRateLimitPolling() {
        Task { await self.pollRateLimits() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.pollRateLimits() }
        }
    }

    private func pollRateLimits() async {
        do {
            let creds = try KeychainCredentials.load()
            let polled = try await apiClient.pingForRateLimits(accessToken: creds.accessToken)
            await MainActor.run {
                self.polledRateLimits = polled
                self.checkAlerts()
            }
        } catch {
            // Silent failure: keychain may need user approval on first launch,
            // or network may be unavailable. Statusline data is still used.
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

    // Rate limits, in preference order:
    //   1. Polled data from Anthropic API (always fresh, ground truth)
    //   2. Live session statusline with non-expired 5h window (fresh local data)
    //   3. Any session with rate-limit data (stale, but better than nothing)
    var rateLimits: RateLimits? {
        if let polled = polledRateLimits {
            return polled.toRateLimits()
        }
        let all = sessions.compactMap(\.rateLimits)
        let fresh = all.filter { !$0.fiveHour.hasReset }
        if let pick = fresh.max(by: { $0.fiveHour.usedPercentage < $1.fiveHour.usedPercentage }) {
            return pick
        }
        return all.max(by: { $0.sevenDay.usedPercentage < $1.sevenDay.usedPercentage })
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

        // Primary source: compute daily activity from history.jsonl (always fresh)
        let historyDays = loadDailyActivityFromHistory()

        // Today/week from history (exclude today from week subtotals to avoid
        // double-counting — today's best data is added separately below)
        let historyToday = historyDays.first { $0.date == today }
        let historyPriorWeek = historyDays.filter { $0.date >= weekAgo && $0.date != today }
        let priorWeekMessages = historyPriorWeek.reduce(0) { $0 + $1.messageCount }
        let priorWeekSessions = historyPriorWeek.reduce(0) { $0 + $1.sessionCount }

        // From session-meta (has tokens, which history lacks)
        let todayMeta = metaSessions.filter { $0.startTime.hasPrefix(today) }
        let metaTokens = todayMeta.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }

        // From live sessions (most current source for tokens)
        let liveSessionCount = sessions.count
        let liveTokens = sessions.reduce(0) { total, s in
            let input = s.contextWindow?.totalInputTokens ?? 0
            let output = s.contextWindow?.totalOutputTokens ?? 0
            return total + input + output
        }

        // Count messages and tools from active session transcripts
        var liveMessages = 0
        var liveUserMessages = 0
        var liveToolCalls = 0
        for session in sessions {
            if let sessionId = session.sessionId {
                let counts = countMessagesInTranscript(sessionId: sessionId)
                liveMessages += counts.messages
                liveUserMessages += counts.userMessages
                liveToolCalls += counts.toolCalls
            }
        }

        // Tokens from stats-cache (supplement, may be stale)
        let todayTokenEntry = stats?.dailyModelTokens.first { $0.date == today }
        let statsTodayTokens = todayTokenEntry?.tokensByModel.values.reduce(0, +) ?? 0
        let weekTokenEntries = stats?.dailyModelTokens.filter { $0.date >= weekAgo } ?? []
        let statsWeekTokens = weekTokenEntries.reduce(0) { $0 + $1.tokensByModel.values.reduce(0, +) }

        // Use the best available data (history > live > meta > stats-cache)
        let bestTodaySessions = max(historyToday?.sessionCount ?? 0, liveSessionCount)
        let bestTodayMessages = max(historyToday?.messageCount ?? 0, liveMessages)
        let bestTodayToolCalls = max(historyToday?.toolCallCount ?? 0, liveToolCalls)
        let bestTodayTokens = max(statsTodayTokens, max(metaTokens, liveTokens))

        return UsageSummary(
            todayMessages: bestTodayMessages,
            todayUserMessages: liveUserMessages,
            todaySessions: bestTodaySessions,
            todayToolCalls: bestTodayToolCalls,
            todayTokens: bestTodayTokens,
            weekMessages: priorWeekMessages + bestTodayMessages,
            weekUserMessages: liveUserMessages,
            weekSessions: priorWeekSessions + bestTodaySessions,
            weekTokens: max(statsWeekTokens, bestTodayTokens),
            recentDays: historyDays.filter { $0.date >= twoWeeksAgo },
            modelBreakdown: mergedModelBreakdown(stats: stats)
        )
    }

    // MARK: - History.jsonl parsing

    // Parse ~/.claude/history.jsonl to compute daily activity. Each line is a
    // user prompt with a timestamp and sessionId. This is always fresh (written
    // on every prompt), unlike stats-cache which may be stale for weeks.
    private func loadDailyActivityFromHistory() -> [DailyActivity] {
        let path = "\(claudeDir)/history.jsonl"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }

        struct HistoryEntry: Codable {
            let timestamp: Double?
            let sessionId: String?
        }

        var daily: [String: (messages: Int, sessions: Set<String>)] = [:]

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(HistoryEntry.self, from: lineData),
                  let ts = entry.timestamp else { continue }
            let date = Date(timeIntervalSince1970: ts / 1000)
            let key = dateString(for: date)
            var day = daily[key] ?? (messages: 0, sessions: Set<String>())
            day.messages += 1
            if let sid = entry.sessionId { day.sessions.insert(sid) }
            daily[key] = day
        }

        return daily.map { key, value in
            DailyActivity(date: key, messageCount: value.messages, sessionCount: value.sessions.count, toolCallCount: 0)
        }.sorted { $0.date < $1.date }
    }

    // Merge live session models into the stats-cache model breakdown so
    // models that appeared after the cache was computed still show up.
    private func mergedModelBreakdown(stats: StatsCache?) -> [String: ModelUsage] {
        var breakdown = stats?.modelUsage ?? [:]
        for session in sessions {
            guard let modelId = session.model?.id else { continue }
            if breakdown[modelId] == nil {
                let input = session.contextWindow?.totalInputTokens ?? 0
                let output = session.contextWindow?.totalOutputTokens ?? 0
                breakdown[modelId] = ModelUsage(
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadInputTokens: 0,
                    cacheCreationInputTokens: 0,
                    webSearchRequests: 0,
                    costUSD: 0
                )
            }
        }
        return breakdown
    }

    private func countMessagesInTranscript(sessionId: String) -> (messages: Int, userMessages: Int, toolCalls: Int) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let projectsDir = "\(home)/.claude/projects"

        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return (0, 0, 0) }
        for dir in dirs {
            let path = "\(projectsDir)/\(dir)/\(sessionId).jsonl"
            guard let data = fm.contents(atPath: path),
                  let content = String(data: data, encoding: .utf8) else { continue }

            var messages = 0
            var userMessages = 0
            var toolCalls = 0
            for line in content.components(separatedBy: .newlines) where !line.isEmpty {
                if line.contains("\"type\":\"user\"") && !line.contains("\"tool_result\"") {
                    // User message (not a tool result)
                    if line.contains("\"userType\":\"external\"") && !line.contains("\"isSidechain\":true") {
                        userMessages += 1
                    }
                    messages += 1
                } else if line.contains("\"type\":\"assistant\"") {
                    messages += 1
                    let toolCount = line.components(separatedBy: "\"type\":\"tool_use\"").count - 1
                    toolCalls += toolCount
                }
            }
            return (messages, userMessages, toolCalls)
        }
        return (0, 0, 0)
    }

    private func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Alerts

    private func checkAlerts() {
        guard let limits = rateLimits else { return }

        fiveHourAlertLevel = evaluateAlert(
            windowLabel: "5-Hour Limit",
            percentage: limits.fiveHour.effectivePercentage,
            resetText: "Resets in \(limits.fiveHour.timeUntilReset)",
            currentLevel: fiveHourAlertLevel
        )

        sevenDayAlertLevel = evaluateAlert(
            windowLabel: "7-Day Limit",
            percentage: limits.sevenDay.effectivePercentage,
            resetText: "Resets \(limits.sevenDay.timeUntilReset)",
            currentLevel: sevenDayAlertLevel
        )
    }

    private func evaluateAlert(windowLabel: String, percentage: Int, resetText: String, currentLevel: AlertLevel) -> AlertLevel {
        let newLevel: AlertLevel
        if percentage >= criticalThreshold {
            newLevel = .critical
        } else if percentage >= warningThreshold {
            newLevel = .warning
        } else {
            newLevel = .none
        }

        // Only notify when crossing up into a higher tier
        if newLevel.rawValue > currentLevel.rawValue {
            let prefix = newLevel == .critical ? "Critical" : "Warning"
            sendNotification(
                title: "Claude \(prefix): \(windowLabel)",
                body: "\(percentage)% used. \(resetText)."
            )
        }
        return newLevel
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
