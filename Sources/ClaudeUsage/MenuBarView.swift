import SwiftUI

struct MenuBarView: View {
    @ObservedObject var service: UsageDataService
    var openBrowser: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                Divider().padding(.vertical, 6)

                if let limits = service.rateLimits {
                    rateLimitsSection(limits)
                    Divider().padding(.vertical, 6)
                } else if service.sessions.isEmpty {
                    setupHint
                    Divider().padding(.vertical, 6)
                }

                if !service.sessions.isEmpty {
                    sessionsSection
                    Divider().padding(.vertical, 6)
                }

                todaySection
                Divider().padding(.vertical, 6)

                weekSection
                Divider().padding(.vertical, 6)

                chartSection
                Divider().padding(.vertical, 6)

                modelSection
                Divider().padding(.vertical, 6)

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
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 32, height: 32)
                Image(systemName: "brain")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Usage")
                    .font(.headline)
                Text("Max (5x)")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            Spacer()
            Button(action: { service.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                resetText: resetText(prefix: "Resets in", window: limits.fiveHour),
                projection: limits.fiveHour.projectionText(windowSeconds: 5 * 3600),
                gradient: [.orange, .red]
            )
            rateLimitRow(
                title: "All models",
                subtitle: "7-day window",
                percentage: limits.sevenDay.effectivePercentage,
                resetText: resetText(prefix: "Resets", window: limits.sevenDay),
                projection: limits.sevenDay.projectionText(windowSeconds: 7 * 86400),
                gradient: [.blue, .purple]
            )
        }
    }

    private func resetText(prefix: String, window: RateWindow) -> String {
        if window.hasReset {
            return "Window reset, awaiting refresh"
        }
        return "\(prefix) \(window.timeUntilReset)"
    }

    private func rateLimitRow(title: String, subtitle: String, percentage: Int, resetText: String, projection: String?, gradient: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(percentage)%")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(limitColor(percentage))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.gray.opacity(0.12))
                        .frame(height: 10)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * CGFloat(percentage) / 100), height: 10)
                }
            }
            .frame(height: 10)
            Text(resetText).font(.caption2).foregroundStyle(.secondary)
            if let projection {
                Text(projection)
                    .font(.caption2)
                    .foregroundStyle(projection.hasPrefix("Hits") ? Color.orange : .secondary)
            }
        }
    }

    // MARK: - Active Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Active Sessions", icon: "bolt.fill", color: .green, count: "\(service.sessions.count)")

            ForEach(Array(service.sessions.enumerated()), id: \.offset) { _, session in
                sessionCard(session)
            }
        }
    }

    private func sessionCard(_ data: StatusLineData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let model = data.model {
                    HStack(spacing: 4) {
                        Circle().fill(Color.purple).frame(width: 6, height: 6)
                        Text(model.displayName).font(.caption.weight(.medium))
                    }
                }
                Spacer()
                if let ctx = data.contextWindow {
                    HStack(spacing: 4) {
                        Text("ctx \(ctx.usedPercentage)%")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Circle()
                            .fill(ctx.usedPercentage >= 80 ? Color.red : ctx.usedPercentage >= 50 ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            if let cwd = data.cwd {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.blue.opacity(0.7))
                    Text(shortenPath(cwd)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if let cost = data.cost {
                HStack {
                    Text("API equiv.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(String(format: "$%.2f", cost.totalCostUsd))
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(.orange)
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
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.08)))
    }

    // MARK: - Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Today", icon: "sun.max.fill", color: .yellow)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ColorStatBadge(icon: "person.fill", value: "\(service.summary.todayUserMessages)", label: "Prompts", color: .blue)
                ColorStatBadge(icon: "message.fill", value: "\(service.summary.todayMessages)", label: "Messages", color: .purple)
                ColorStatBadge(icon: "terminal.fill", value: "\(service.summary.todaySessions)", label: "Sessions", color: .green)
                ColorStatBadge(icon: "hammer.fill", value: "\(service.summary.todayToolCalls)", label: "Tools", color: .orange)
                ColorStatBadge(icon: "number", value: formatTokens(service.summary.todayTokens), label: "Tokens", color: .cyan)
            }
        }
    }

    // MARK: - This Week

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("This Week", icon: "calendar", color: .blue)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ColorStatBadge(icon: "person.fill", value: "\(service.summary.weekUserMessages)", label: "Prompts", color: .blue)
                ColorStatBadge(icon: "message.fill", value: "\(service.summary.weekMessages)", label: "Messages", color: .purple)
                ColorStatBadge(icon: "terminal.fill", value: "\(service.summary.weekSessions)", label: "Sessions", color: .green)
                ColorStatBadge(icon: "number", value: formatTokens(service.summary.weekTokens), label: "Tokens", color: .cyan)
            }
        }
    }

    // MARK: - Activity Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Recent Activity", icon: "chart.bar.fill", color: .purple)
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
            sectionHeader("Models", icon: "cpu.fill", color: .cyan)
            ForEach(
                service.summary.modelBreakdown.sorted(by: { $0.value.outputTokens > $1.value.outputTokens }),
                id: \.key
            ) { model, usage in
                HStack {
                    Circle().fill(modelColor(model)).frame(width: 8, height: 8)
                    Text(shortModelName(model)).font(.caption).fontWeight(.medium)
                    Spacer()
                    Text("\(formatTokens(usage.inputTokens + usage.outputTokens)) tokens")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Recent Sessions

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Recent Sessions", icon: "clock.fill", color: .orange)
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
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
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
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Sessions")
                }
                .font(.caption)
                .foregroundStyle(.purple)
            }
            .buttonStyle(.borderless)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Setup Hint

    private var setupHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
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
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.08)))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.1)))
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, icon: String, color: Color, count: String? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if let count {
                Text(count)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(color.opacity(0.12)))
            }
            Spacer()
        }
    }

    // MARK: - Helpers

    private func limitColor(_ p: Int) -> Color {
        p >= 80 ? .red : p >= 60 ? .orange : .green
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

// MARK: - Colored Stat Badge

struct ColorStatBadge: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.caption, design: .rounded).weight(.bold))
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.06)))
    }
}

// MARK: - Activity Chart

struct ActivityChart: View {
    let days: [DailyActivity]

    var body: some View {
        let maxMessages = days.map(\.messageCount).max() ?? 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(days) { day in
                VStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: barColors(day.messageCount, max: maxMessages),
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 14, height: max(2, CGFloat(day.messageCount) / CGFloat(maxMessages) * 50))
                    Text(dayLabel(day.date)).font(.system(size: 7)).foregroundStyle(.tertiary)
                }
                .help("\(day.date): \(day.messageCount) messages, \(day.sessionCount) sessions")
            }
        }
    }

    private func barColors(_ value: Int, max: Int) -> [Color] {
        let ratio = Double(value) / Double(max)
        if ratio > 0.7 { return [.purple, .pink] }
        if ratio > 0.3 { return [.blue, .purple] }
        return [.blue.opacity(0.4), .blue.opacity(0.6)]
    }

    private func dayLabel(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        return parts.count == 3 ? String(parts[2]) : ""
    }
}
