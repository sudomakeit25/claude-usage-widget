import SwiftUI

struct MenuBarView: View {
    @ObservedObject var service: UsageDataService
    var openBrowser: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                Divider().padding(.vertical, 6)

                // Rate limits (account-level)
                if let limits = service.rateLimits {
                    rateLimitsSection(limits)
                    Divider().padding(.vertical, 6)
                } else if service.sessions.isEmpty {
                    setupHint
                    Divider().padding(.vertical, 6)
                }

                // Active sessions
                if !service.sessions.isEmpty {
                    sessionsSection
                    Divider().padding(.vertical, 6)
                }

                // Today
                todaySection
                Divider().padding(.vertical, 6)

                // This Week
                weekSection
                Divider().padding(.vertical, 6)

                // Recent Activity chart
                chartSection
                Divider().padding(.vertical, 6)

                // Models
                modelSection
                Divider().padding(.vertical, 6)

                // Recent Sessions
                recentSessionsSection
                Divider().padding(.vertical, 6)

                footerSection
            }
            .padding(14)
        }
        .frame(width: 320, height: 600)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "brain")
                .font(.title3)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Usage")
                    .font(.headline)
                Text("Max (5x)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { service.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Rate Limits

    private func rateLimitsSection(_ limits: RateLimits) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            rateLimitRow(
                title: "Current session",
                subtitle: "5-hour window",
                percentage: limits.fiveHour.effectivePercentage,
                resetText: "Resets in \(limits.fiveHour.timeUntilReset)",
                color: limitColor(limits.fiveHour.effectivePercentage)
            )
            rateLimitRow(
                title: "All models",
                subtitle: "7-day window",
                percentage: limits.sevenDay.effectivePercentage,
                resetText: "Resets \(limits.sevenDay.timeUntilReset)",
                color: limitColor(limits.sevenDay.effectivePercentage)
            )
        }
    }

    private func rateLimitRow(title: String, subtitle: String, percentage: Int, resetText: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(percentage)% used")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)).frame(height: 8)
                    RoundedRectangle(cornerRadius: 4).fill(color.gradient)
                        .frame(width: max(0, geo.size.width * CGFloat(percentage) / 100), height: 8)
                }
            }
            .frame(height: 8)
            Text(resetText).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Active Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active Sessions (\(service.sessions.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(service.sessions.enumerated()), id: \.offset) { index, session in
                sessionCard(session)
            }
        }
    }

    private func sessionCard(_ data: StatusLineData) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if let model = data.model {
                    Text(model.displayName).font(.caption.weight(.medium))
                }
                Spacer()
                if let ctx = data.contextWindow {
                    Text("ctx \(ctx.usedPercentage)%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Circle().fill(ctx.usedPercentage >= 80 ? Color.red : ctx.usedPercentage >= 50 ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            if let cwd = data.cwd {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(shortenPath(cwd)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if let cost = data.cost {
                HStack {
                    Text("API equiv. \(String(format: "$%.2f", cost.totalCostUsd))")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    if let added = cost.totalLinesAdded, added > 0 {
                        Text("+\(added)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.green)
                    }
                    if let removed = cost.totalLinesRemoved, removed > 0 {
                        Text("-\(removed)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    // MARK: - Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                StatBadge(icon: "person", value: "\(service.summary.todayUserMessages)", label: "Prompts")
                StatBadge(icon: "message", value: "\(service.summary.todayMessages)", label: "Messages")
                StatBadge(icon: "terminal", value: "\(service.summary.todaySessions)", label: "Sessions")
                StatBadge(icon: "hammer", value: "\(service.summary.todayToolCalls)", label: "Tools")
                StatBadge(icon: "number", value: formatTokens(service.summary.todayTokens), label: "Tokens")
            }
        }
    }

    // MARK: - This Week

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This Week").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                StatBadge(icon: "person", value: "\(service.summary.weekUserMessages)", label: "Prompts")
                StatBadge(icon: "message", value: "\(service.summary.weekMessages)", label: "Messages")
                StatBadge(icon: "terminal", value: "\(service.summary.weekSessions)", label: "Sessions")
                StatBadge(icon: "number", value: formatTokens(service.summary.weekTokens), label: "Tokens")
            }
        }
    }

    // MARK: - Activity Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Activity").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if service.summary.recentDays.isEmpty {
                Text("No recent data").font(.caption).foregroundStyle(.tertiary)
            } else {
                ActivityChart(days: service.summary.recentDays).frame(height: 60)
            }
        }
    }

    // MARK: - Models

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models (All Time)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(
                service.summary.modelBreakdown.sorted(by: { $0.value.outputTokens > $1.value.outputTokens }),
                id: \.key
            ) { model, usage in
                HStack {
                    Circle().fill(modelColor(model)).frame(width: 8, height: 8)
                    Text(shortModelName(model)).font(.caption)
                    Spacer()
                    Text("\(formatTokens(usage.inputTokens + usage.outputTokens)) tokens")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Recent Sessions

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Sessions").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(service.recentSessions.prefix(5)) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.firstPrompt?.prefix(40).description ?? "Session")
                            .font(.caption).lineLimit(1)
                        Text(formatSessionTime(session.startTime))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("\(session.userMessageCount + session.assistantMessageCount) msgs")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("Updated \(formatTime(service.lastUpdated))")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button(action: openBrowser) {
                Label("Sessions", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).font(.caption)
        }
    }

    // MARK: - Helpers

    // MARK: - Setup Hint

    private var setupHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                Text("Setup Required")
                    .font(.subheadline.weight(.medium))
            }
            Text("No live data yet. Start a Claude Code session to see rate limits and usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("If this is your first time, run:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("bash Scripts/setup.sh")
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.1)))
        }
    }

    private func limitColor(_ p: Int) -> Color {
        p >= 80 ? .red : p >= 50 ? .orange : .green
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func shortModelName(_ name: String) -> String {
        if name.contains("opus-4-6") { return "Opus 4.6" }
        if name.contains("opus-4-5") { return "Opus 4.5" }
        if name.contains("sonnet-4-6") { return "Sonnet 4.6" }
        if name.contains("sonnet-4-5") { return "Sonnet 4.5" }
        if name.contains("haiku-4-5") { return "Haiku 4.5" }
        return name
    }

    private func modelColor(_ name: String) -> Color {
        if name.contains("opus") { return .purple }
        if name.contains("sonnet") { return .blue }
        if name.contains("haiku") { return .green }
        return .gray
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }

    private func formatSessionTime(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) else { return iso }
        let r = RelativeDateTimeFormatter(); r.unitsStyle = .abbreviated
        return r.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Reusable components

struct StatBadge: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced).weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ActivityChart: View {
    let days: [DailyActivity]

    var body: some View {
        let maxMessages = days.map(\.messageCount).max() ?? 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(days) { day in
                VStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(day.messageCount, max: maxMessages))
                        .frame(width: 14, height: max(2, CGFloat(day.messageCount) / CGFloat(maxMessages) * 50))
                    Text(dayLabel(day.date)).font(.system(size: 7)).foregroundStyle(.tertiary)
                }
                .help("\(day.date): \(day.messageCount) messages, \(day.sessionCount) sessions")
            }
        }
    }

    private func barColor(_ value: Int, max: Int) -> Color {
        let ratio = Double(value) / Double(max)
        return ratio > 0.7 ? .purple : ratio > 0.3 ? .blue : .blue.opacity(0.5)
    }

    private func dayLabel(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        return parts.count == 3 ? String(parts[2]) : ""
    }
}
