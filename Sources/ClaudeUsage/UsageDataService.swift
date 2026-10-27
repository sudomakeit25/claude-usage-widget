import Foundation
import UserNotifications
import os

private let pollLog = Logger(subsystem: "com.local.claude-usage", category: "ratelimits")

final class UsageDataService: ObservableObject {
    // Live session data
    @Published var sessions: [StatusLineData] = []
    @Published var lastUpdated: Date = Date()

    // Historical stats
    @Published var summary: UsageSummary = .empty
    @Published var recentSessions: [SessionMeta] = []

    // Per live session transcript stats, keyed by session id
    @Published var transcriptStats: [String: TranscriptCounter.Counts] = [:]
    // Recent pace against the 5-hour limit and API-equivalent spend
    @Published var burnRate: BurnRateTracker.Snapshot?
    private var burnTracker = BurnRateTracker()

    // Transcript size above which a session is flagged as large
    static let largeTranscriptBytes: UInt64 = 100 * 1_000_000
    static let hugeTranscriptBytes: UInt64 = 250 * 1_000_000
    private var largeTranscriptAlerted = Set<String>()

    private let claudeDir: String
    private let sessionStatusDir: String
    private let rateLimitsPath: String
    private let statsPath: String
    private let sessionMetaDir: String
    private var refreshTimer: Timer?
    private var refreshInFlight = false

    // Only touched from refresh passes, which never overlap
    private let transcriptCounter = TranscriptCounter()
    private var transcriptPaths: [String: String] = [:]

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
            pollLog.info("Polled rate limits: 5h=\(Int(polled.fiveHourPercent.rounded()), privacy: .public)% 7d=\(Int(polled.sevenDayPercent.rounded()), privacy: .public)%")
            await MainActor.run {
                self.polledRateLimits = polled
                self.checkAlerts()
            }
        } catch {
            // Keychain read or network failure. Statusline data is still used.
            // Inspect with: log show --predicate 'subsystem == "com.local.claude-usage"' --last 1h
            pollLog.error("Rate-limit poll failed: \(String(describing: error), privacy: .public)")
        }
    }

    func refresh() {
        // Skip while the previous pass is still running so slow passes
        // (large transcripts) can't pile up on the background queue
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let liveSessions = self.loadAllLiveSessions()
            let stats = self.loadStatsCache()
            let metaSessions = self.loadRecentSessions(limit: 5)
            let (summary, transcriptStats) = self.buildSummary(stats: stats, metaSessions: metaSessions, liveSessions: liveSessions)

            DispatchQueue.main.async {
                self.sessions = liveSessions
                self.summary = summary
                self.transcriptStats = transcriptStats
                self.recentSessions = metaSessions
                self.lastUpdated = Date()
                self.updateBurnRate()
                self.checkAlerts()
                self.checkLargeTranscripts()
                self.refreshInFlight = false
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

    private func buildSummary(stats: StatsCache?, metaSessions: [SessionMeta], liveSessions: [StatusLineData]) -> (UsageSummary, [String: TranscriptCounter.Counts]) {
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
        let liveSessionCount = liveSessions.count
        let liveTokens = liveSessions.reduce(0) { total, s in
            let input = s.contextWindow?.totalInputTokens ?? 0
            let output = s.contextWindow?.totalOutputTokens ?? 0
            return total + input + output
        }

        // Count messages and tools from active session transcripts
        var liveMessages = 0
        var liveUserMessages = 0
        var liveToolCalls = 0
        var livePaths = Set<String>()
        var transcriptStats: [String: TranscriptCounter.Counts] = [:]
        for session in liveSessions {
            if let sessionId = session.sessionId,
               let path = transcriptPath(sessionId: sessionId),
               let counts = transcriptCounter.counts(atPath: path) {
                livePaths.insert(path)
                transcriptStats[sessionId] = counts
                liveMessages += counts.messages
                liveUserMessages += counts.userMessages
                liveToolCalls += counts.toolCalls
            }
        }
        transcriptCounter.retainOnly(paths: livePaths)

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

        let summary = UsageSummary(
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
            modelBreakdown: mergedModelBreakdown(stats: stats, liveSessions: liveSessions)
        )
        return (summary, transcriptStats)
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
    private func mergedModelBreakdown(stats: StatsCache?, liveSessions: [StatusLineData]) -> [String: ModelUsage] {
        var breakdown = stats?.modelUsage ?? [:]
        for session in liveSessions {
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

    private func transcriptPath(sessionId: String) -> String? {
        let fm = FileManager.default
        if let cached = transcriptPaths[sessionId], fm.fileExists(atPath: cached) {
            return cached
        }
        let projectsDir = "\(claudeDir)/projects"
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return nil }
        for dir in dirs {
            let path = "\(projectsDir)/\(dir)/\(sessionId).jsonl"
            if fm.fileExists(atPath: path) {
                transcriptPaths[sessionId] = path
                return path
            }
        }
        return nil
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

    private func updateBurnRate() {
        let now = Date()
        var costs: [String: Double] = [:]
        for s in sessions {
            if let id = s.sessionId, let cost = s.cost?.totalCostUsd {
                costs[id] = max(costs[id] ?? 0, cost)
            }
        }
        let fiveHour = rateLimits?.fiveHour
        burnTracker.record(at: now, fiveHour: fiveHour, sessionCosts: costs)
        burnRate = burnTracker.snapshot(at: now, fiveHour: fiveHour)
    }

    // Notify once per session when its transcript passes the large threshold.
    // Huge transcripts slow Claude Code and anything that reads them.
    private func checkLargeTranscripts() {
        for (sessionId, counts) in transcriptStats where counts.bytes >= Self.largeTranscriptBytes {
            guard !largeTranscriptAlerted.contains(sessionId) else { continue }
            largeTranscriptAlerted.insert(sessionId)
            let project = sessions.first { $0.sessionId == sessionId }?.cwd
                .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a session"
            sendNotification(
                title: "Large Claude session",
                body: "Transcript for \(project) is \(Self.formatBytes(counts.bytes)). Consider starting a fresh session."
            )
        }
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        if mb >= 10 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
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
