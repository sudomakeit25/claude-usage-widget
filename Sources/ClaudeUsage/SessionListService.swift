import Foundation

struct DayTokens: Hashable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheCreate: Int = 0

    // Opus-rate estimate
    var estimatedCost: Double {
        Double(input) * 15.0 / 1_000_000 +
        Double(output) * 75.0 / 1_000_000 +
        Double(cacheRead) * 1.50 / 1_000_000 +
        Double(cacheCreate) * 18.75 / 1_000_000
    }
}

struct SessionInfo: Identifiable, Hashable {
    var id: String { sessionId }
    let sessionId: String
    let projectPath: String
    let projectName: String
    let startTime: Date
    let durationMinutes: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let firstPrompt: String
    let toolCounts: [String: Int]
    let inputTokens: Int
    let outputTokens: Int
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    // Per-day token usage keyed by "yyyy-MM-dd" (UTC). Lets the cost chart
    // attribute long-running sessions to the days they were actually active.
    var dailyTokens: [String: DayTokens] = [:]
    // Per-model token usage. Lets the cost-by-model chart use transcript
    // data instead of the often-stale stats-cache.
    var modelTokens: [String: DayTokens] = [:]
    let linesAdded: Int
    let linesRemoved: Int
    let transcriptPath: String?
    var isBookmarked: Bool = false
    var isPinned: Bool = false
    var customTitle: String?
    var liveCostUsd: Double?

    var totalMessages: Int { userMessageCount + assistantMessageCount }
    var displayTitle: String { customTitle ?? (firstPrompt.isEmpty ? "Session" : firstPrompt) }

    // The model that accounted for the most input+output tokens in this session.
    // A session may span model upgrades (e.g. Opus 4.6 → 4.7 → 4.8), so we
    // pick the dominant one. nil if no transcript data is available.
    var primaryModel: String? {
        guard !modelTokens.isEmpty else { return nil }
        return modelTokens.max(by: { lhs, rhs in
            (lhs.value.input + lhs.value.output) < (rhs.value.input + rhs.value.output)
        })?.key
    }

    // Short label like "Opus 4.7" or "Sonnet 4.6". Returns nil if no model
    // info is available so callers can hide the badge entirely.
    var shortModelName: String? {
        guard let id = primaryModel else { return nil }
        let parts = id.split(separator: "-")
        guard parts.count >= 4 else { return id }
        let family = parts[1].capitalized
        return "\(family) \(parts[2]).\(parts[3])"
    }

    // Use live cost if available, otherwise estimate from tokens at Opus rates
    // ($15/M in, $75/M out, $1.50/M cache-read, $18.75/M cache-write). For
    // long-running cache-heavy sessions, cache tokens dominate — without them
    // the estimate is 10–100× low.
    var estimatedCost: Double {
        if let live = liveCostUsd { return live }
        let inputCost = Double(inputTokens) * 15.0 / 1_000_000
        let outputCost = Double(outputTokens) * 75.0 / 1_000_000
        let cacheReadCost = Double(cacheReadTokens) * 1.50 / 1_000_000
        let cacheCreateCost = Double(cacheCreationTokens) * 18.75 / 1_000_000
        return inputCost + outputCost + cacheReadCost + cacheCreateCost
    }

    static func == (lhs: SessionInfo, rhs: SessionInfo) -> Bool {
        lhs.sessionId == rhs.sessionId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sessionId)
    }
}

struct ProjectGroup: Identifiable {
    var id: String { projectPath }
    let projectPath: String
    let projectName: String
    let sessions: [SessionInfo]
}

enum SessionFilter: String, CaseIterable {
    case all = "All"
    case today = "Today"
    case thisWeek = "This Week"
    case thisMonth = "This Month"
    case bookmarked = "Bookmarked"
}

final class SessionListService: ObservableObject {
    @Published var allSessions: [SessionInfo] = []
    @Published var projects: [ProjectGroup] = []
    @Published var isLoading = false
    @Published var projectNames: [String] = []

    private let claudeDir: String
    private let sessionMetaDir: String
    private let projectsDir: String
    private let bookmarksPath: String
    private let pinsPath: String
    private let titlesPath: String
    private var bookmarks: Set<String> = []
    private var pins: Set<String> = []
    private var titles: [String: String] = [:]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        claudeDir = "\(home)/.claude"
        sessionMetaDir = "\(claudeDir)/usage-data/session-meta"
        projectsDir = "\(claudeDir)/projects"
        bookmarksPath = "\(claudeDir)/bookmarks.json"
        pinsPath = "\(claudeDir)/pins.json"
        titlesPath = "\(claudeDir)/session-titles.json"
        loadBookmarks()
        loadPins()
        loadTitles()
    }

    func loadAll() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var sessions = self.loadAllSessions()

            // Merge in active sessions and live cost data from session-status
            let activeSessions = self.loadActiveSessions()
            let liveCosts = self.loadLiveCosts()
            let existingIds = Set(sessions.map { $0.sessionId })
            for active in activeSessions where !existingIds.contains(active.sessionId) {
                sessions.append(active)
            }
            // Apply live costs to existing sessions
            for i in sessions.indices {
                if let cost = liveCosts[sessions[i].sessionId] {
                    sessions[i].liveCostUsd = cost
                }
            }

            sessions.sort { $0.startTime > $1.startTime }

            // Apply bookmarks, pins, titles
            for i in sessions.indices {
                let sid = sessions[i].sessionId
                sessions[i].isBookmarked = self.bookmarks.contains(sid)
                sessions[i].isPinned = self.pins.contains(sid)
                sessions[i].customTitle = self.titles[sid]
            }

            let grouped = self.groupByProject(sessions)
            let names = Array(Set(sessions.map { $0.projectName })).sorted()

            DispatchQueue.main.async {
                self.allSessions = sessions
                self.projects = grouped
                self.projectNames = names
                self.isLoading = false
            }
        }
    }

    // Load live cost data from session-status files
    private func loadLiveCosts() -> [String: Double] {
        let fm = FileManager.default
        let statusDir = "\(claudeDir)/session-status"
        guard let files = try? fm.contentsOfDirectory(atPath: statusDir) else { return [:] }

        var costs: [String: Double] = [:]
        for file in files where file.hasSuffix(".json") {
            let path = "\(statusDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let status = try? JSONDecoder().decode(StatusLineData.self, from: data),
                  let sessionId = status.sessionId,
                  let cost = status.cost?.totalCostUsd else { continue }
            costs[sessionId] = cost
        }

        let rateLimitsPath = "\(claudeDir)/rate-limits.json"
        if let data = fm.contents(atPath: rateLimitsPath),
           let status = try? JSONDecoder().decode(StatusLineData.self, from: data),
           let sessionId = status.sessionId,
           let cost = status.cost?.totalCostUsd {
            costs[sessionId] = cost
        }

        return costs
    }

    // Load active sessions from statusline data (for sessions that don't have meta files yet)
    private func loadActiveSessions() -> [SessionInfo] {
        let fm = FileManager.default
        let statusDir = "\(claudeDir)/session-status"
        guard let files = try? fm.contentsOfDirectory(atPath: statusDir) else { return [] }

        var sessions: [SessionInfo] = []
        let now = Date()

        for file in files where file.hasSuffix(".json") {
            let path = "\(statusDir)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(modDate) < 86400,
                  let data = fm.contents(atPath: path),
                  let status = try? JSONDecoder().decode(StatusLineData.self, from: data),
                  let sessionId = status.sessionId else { continue }

            let projectPath = status.cwd ?? "Unknown"
            let transcriptPath = findTranscript(sessionId: sessionId, projectPath: projectPath)

            // Parse transcript for accurate token usage including cache reads and per-day/per-model breakdown
            let perDay: [String: DayTokens]
            let perModel: [String: DayTokens]
            let total: DayTokens
            if let tp = transcriptPath {
                (perDay, perModel, total) = parseTranscriptUsage(at: tp)
            } else {
                perDay = [:]
                perModel = [:]
                total = DayTokens(
                    input: status.contextWindow?.totalInputTokens ?? 0,
                    output: status.contextWindow?.totalOutputTokens ?? 0,
                    cacheRead: 0,
                    cacheCreate: 0
                )
            }

            sessions.append(SessionInfo(
                sessionId: sessionId,
                projectPath: projectPath,
                projectName: extractProjectName(projectPath),
                startTime: modDate,
                durationMinutes: 0,
                userMessageCount: 0,
                assistantMessageCount: 0,
                firstPrompt: "(Active session)",
                toolCounts: [:],
                inputTokens: total.input,
                outputTokens: total.output,
                cacheReadTokens: total.cacheRead,
                cacheCreationTokens: total.cacheCreate,
                dailyTokens: perDay,
                modelTokens: perModel,
                linesAdded: status.cost?.totalLinesAdded ?? 0,
                linesRemoved: status.cost?.totalLinesRemoved ?? 0,
                transcriptPath: transcriptPath
            ))
        }

        return sessions
    }

    // MARK: - Bookmarks

    func toggleBookmark(_ sessionId: String) {
        if bookmarks.contains(sessionId) {
            bookmarks.remove(sessionId)
        } else {
            bookmarks.insert(sessionId)
        }
        saveBookmarks()

        if let idx = allSessions.firstIndex(where: { $0.sessionId == sessionId }) {
            allSessions[idx].isBookmarked = bookmarks.contains(sessionId)
        }
    }

    private func loadBookmarks() {
        guard let data = FileManager.default.contents(atPath: bookmarksPath),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        bookmarks = Set(list)
    }

    private func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(Array(bookmarks)) else { return }
        FileManager.default.createFile(atPath: bookmarksPath, contents: data)
    }

    // MARK: - Pins

    func togglePin(_ sessionId: String) {
        if pins.contains(sessionId) {
            pins.remove(sessionId)
        } else {
            pins.insert(sessionId)
        }
        savePins()
        if let idx = allSessions.firstIndex(where: { $0.sessionId == sessionId }) {
            allSessions[idx].isPinned = pins.contains(sessionId)
        }
    }

    private func loadPins() {
        guard let data = FileManager.default.contents(atPath: pinsPath),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        pins = Set(list)
    }

    private func savePins() {
        guard let data = try? JSONEncoder().encode(Array(pins)) else { return }
        FileManager.default.createFile(atPath: pinsPath, contents: data)
    }

    // MARK: - Rename

    func renameSession(_ sessionId: String, title: String?) {
        if let title, !title.isEmpty {
            titles[sessionId] = title
        } else {
            titles.removeValue(forKey: sessionId)
        }
        saveTitles()
        if let idx = allSessions.firstIndex(where: { $0.sessionId == sessionId }) {
            allSessions[idx].customTitle = titles[sessionId]
        }
    }

    private func loadTitles() {
        guard let data = FileManager.default.contents(atPath: titlesPath),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        titles = dict
    }

    private func saveTitles() {
        guard let data = try? JSONEncoder().encode(titles) else { return }
        FileManager.default.createFile(atPath: titlesPath, contents: data)
    }

    // MARK: - Delete

    func deleteSession(_ session: SessionInfo) {
        // Remove session meta
        let metaPath = "\(sessionMetaDir)/\(session.sessionId).json"
        try? FileManager.default.removeItem(atPath: metaPath)

        // Remove transcript
        if let path = session.transcriptPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        // Remove from list
        allSessions.removeAll { $0.sessionId == session.sessionId }
        projects = groupByProject(allSessions)
    }

    // MARK: - Search transcript content

    func searchContent(query: String) -> [SessionInfo] {
        guard !query.isEmpty else { return allSessions }
        let lowerQuery = query.lowercased()

        return allSessions.filter { session in
            // Search first prompt
            if session.firstPrompt.lowercased().contains(lowerQuery) { return true }
            if session.projectName.lowercased().contains(lowerQuery) { return true }

            // Search transcript content
            guard let path = session.transcriptPath,
                  let data = FileManager.default.contents(atPath: path),
                  let content = String(data: data, encoding: .utf8) else { return false }
            return content.lowercased().contains(lowerQuery)
        }
    }

    // MARK: - Filter

    func filtered(sessions: [SessionInfo], by filter: SessionFilter, project: String?) -> [SessionInfo] {
        var result = sessions

        // Date filter
        let calendar = Calendar.current
        let now = Date()
        switch filter {
        case .all: break
        case .today:
            result = result.filter { calendar.isDateInToday($0.startTime) }
        case .thisWeek:
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
            result = result.filter { $0.startTime >= weekAgo }
        case .thisMonth:
            let monthAgo = calendar.date(byAdding: .month, value: -1, to: now)!
            result = result.filter { $0.startTime >= monthAgo }
        case .bookmarked:
            result = result.filter { $0.isBookmarked }
        }

        // Project filter
        if let project, !project.isEmpty {
            result = result.filter { $0.projectName == project }
        }

        return result
    }

    // MARK: - Export

    static func exportToMarkdown(_ session: SessionInfo, messages: [ConversationMessage]) -> String {
        var md = "# \(session.firstPrompt.isEmpty ? "Session" : session.firstPrompt)\n\n"
        md += "**Project:** \(session.projectPath)  \n"
        md += "**Date:** \(ISO8601DateFormatter().string(from: session.startTime))  \n"
        md += "**Duration:** \(session.durationMinutes) min  \n"
        md += "**Messages:** \(session.totalMessages)  \n"
        md += "**Tokens:** \(session.inputTokens + session.outputTokens)  \n\n"
        md += "---\n\n"

        for msg in messages {
            let role = msg.role == .user ? "**You**" : "**Claude**"
            md += "\(role)\n\n"

            if !msg.textContent.isEmpty {
                md += "\(msg.textContent)\n\n"
            }

            for tool in msg.toolUses {
                md += "> Tool: \(tool.name)\n"
                md += "> ```\n> \(tool.input.prefix(500))\n> ```\n\n"
            }

            if let result = msg.toolResult {
                let label = result.isError ? "Error" : "Result"
                md += "> \(label):\n> ```\n> \(result.content.prefix(500))\n> ```\n\n"
            }

            md += "---\n\n"
        }

        return md
    }

    // MARK: - Private

    private func loadAllSessions() -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionMetaDir) else { return [] }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var sessions: [SessionInfo] = []

        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionMetaDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let meta = try? JSONDecoder().decode(SessionMeta.self, from: data) else { continue }

            let startDate = isoFormatter.date(from: meta.startTime) ?? Date.distantPast
            let projectPath = meta.projectPath ?? "Unknown"
            let projectName = extractProjectName(projectPath)
            let transcriptPath = findTranscript(sessionId: meta.sessionId, projectPath: projectPath)

            // Get cache token counts and per-day/per-model breakdowns by
            // parsing the transcript (session-meta has neither)
            let perDay: [String: DayTokens]
            let perModel: [String: DayTokens]
            let total: DayTokens
            if let tp = transcriptPath {
                (perDay, perModel, total) = parseTranscriptUsage(at: tp)
            } else {
                perDay = [:]
                perModel = [:]
                total = DayTokens(input: meta.inputTokens, output: meta.outputTokens, cacheRead: 0, cacheCreate: 0)
            }

            sessions.append(SessionInfo(
                sessionId: meta.sessionId,
                projectPath: projectPath,
                projectName: projectName,
                startTime: startDate,
                durationMinutes: meta.durationMinutes ?? 0,
                userMessageCount: meta.userMessageCount,
                assistantMessageCount: meta.assistantMessageCount,
                firstPrompt: meta.firstPrompt ?? "",
                toolCounts: meta.toolCounts ?? [:],
                inputTokens: max(total.input, meta.inputTokens),
                outputTokens: max(total.output, meta.outputTokens),
                cacheReadTokens: total.cacheRead,
                cacheCreationTokens: total.cacheCreate,
                dailyTokens: perDay,
                modelTokens: perModel,
                linesAdded: meta.linesAdded ?? 0,
                linesRemoved: meta.linesRemoved ?? 0,
                transcriptPath: transcriptPath
            ))
        }

        sessions.sort { $0.startTime > $1.startTime }
        return sessions
    }

    private func groupByProject(_ sessions: [SessionInfo]) -> [ProjectGroup] {
        let grouped = Dictionary(grouping: sessions) { $0.projectPath }
        return grouped.map { path, sessions in
            ProjectGroup(
                projectPath: path,
                projectName: sessions.first?.projectName ?? path,
                sessions: sessions.sorted { $0.startTime > $1.startTime }
            )
        }.sorted { $0.sessions.first?.startTime ?? .distantPast > $1.sessions.first?.startTime ?? .distantPast }
    }

    private func extractProjectName(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count >= 2 {
            return String(components.suffix(2).joined(separator: "/"))
        }
        return String(components.last ?? "Unknown")
    }

    // Scan a transcript JSONL for usage data, broken down by day and by
    // model. Each transcript line carries a timestamp and the model that
    // produced the message, so we can bin per-message tokens to both axes.
    private func parseTranscriptUsage(at path: String) -> (perDay: [String: DayTokens], perModel: [String: DayTokens], total: DayTokens) {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return ([:], [:], DayTokens()) }

        var perDay: [String: DayTokens] = [:]
        var perModel: [String: DayTokens] = [:]
        var total = DayTokens()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let msg = json["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }

            let input       = (usage["input_tokens"] as? Int) ?? 0
            let output      = (usage["output_tokens"] as? Int) ?? 0
            let cacheRead   = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0

            total.input += input
            total.output += output
            total.cacheRead += cacheRead
            total.cacheCreate += cacheCreate

            // Bin to local day (fallback to "unknown" if timestamp missing)
            let dayKey: String
            if let ts = json["timestamp"] as? String, let date = isoFormatter.date(from: ts) {
                dayKey = dayFormatter.string(from: date)
            } else {
                dayKey = "unknown"
            }
            var dayBucket = perDay[dayKey] ?? DayTokens()
            dayBucket.input += input
            dayBucket.output += output
            dayBucket.cacheRead += cacheRead
            dayBucket.cacheCreate += cacheCreate
            perDay[dayKey] = dayBucket

            // Bin by model
            let modelKey = (msg["model"] as? String) ?? "unknown"
            var modelBucket = perModel[modelKey] ?? DayTokens()
            modelBucket.input += input
            modelBucket.output += output
            modelBucket.cacheRead += cacheRead
            modelBucket.cacheCreate += cacheCreate
            perModel[modelKey] = modelBucket
        }
        return (perDay, perModel, total)
    }

    private func findTranscript(sessionId: String, projectPath: String) -> String? {
        let encoded = projectPath
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let transcriptPath = "\(projectsDir)/\(encoded)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: transcriptPath) {
            return transcriptPath
        }

        let fm = FileManager.default
        if let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) {
            for dir in dirs {
                let candidatePath = "\(projectsDir)/\(dir)/\(sessionId).jsonl"
                if fm.fileExists(atPath: candidatePath) {
                    return candidatePath
                }
            }
        }
        return nil
    }
}
