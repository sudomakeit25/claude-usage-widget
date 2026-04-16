import SwiftUI
import Charts

struct UsageChartsView: View {
    let sessions: [SessionInfo]
    var onSelectSession: ((SessionInfo) -> Void)?
    @State private var selectedCostDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Usage Overview")
                .font(.headline)

            // Stat cards
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                statCard("Sessions", value: "\(sessions.count)", icon: "terminal")
                statCard("Messages", value: formatNumber(sessions.reduce(0) { $0 + $1.totalMessages }), icon: "message")
                statCard("Tokens", value: formatTokens(sessions.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }), icon: "number")
                statCard("Lines Changed", value: formatNumber(sessions.reduce(0) { $0 + $1.linesAdded + $1.linesRemoved }), icon: "text.badge.plus")
                statCard("API Cost", value: String(format: "$%.0f", sessions.reduce(0.0) { $0 + $1.estimatedCost }), icon: "dollarsign.circle")
            }

            // Row 1: Daily sessions + Daily cost
            HStack(spacing: 20) {
                chartCard("Daily Sessions") {
                    if !dailyData.isEmpty {
                        Chart(dailyData, id: \.date) { item in
                            BarMark(x: .value("Date", item.date, unit: .day), y: .value("Sessions", item.count))
                                .foregroundStyle(Color.purple.gradient)
                                .cornerRadius(3)
                        }
                        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                        .frame(height: 140)
                    }
                }

                chartCard("Daily Cost (API equiv.)") {
                    dailyCostChart
                }
            }

            // Row 2: Hourly heatmap + Session duration
            HStack(spacing: 20) {
                chartCard("Activity by Hour") {
                    hourlyHeatmap
                }

                chartCard("Session Duration") {
                    durationHistogram
                }
            }

            // Row 3: Cost per project + Sessions per project
            HStack(spacing: 20) {
                chartCard("Cost per Project") {
                    costPerProjectChart
                }

                chartCard("Sessions per Project") {
                    sessionsPerProjectChart
                }
            }

            // Row 4: Tool usage + Lines per project
            HStack(spacing: 20) {
                chartCard("Top Tools Used") {
                    if !topTools.isEmpty {
                        Chart(topTools, id: \.name) { tool in
                            BarMark(x: .value("Count", tool.count), y: .value("Tool", tool.name))
                                .foregroundStyle(Color.orange.gradient)
                                .cornerRadius(3)
                        }
                        .frame(height: 150)
                    }
                }

                chartCard("Lines Changed per Project") {
                    linesPerProjectChart
                }
            }

            // Row 5: Tokens per message + Session length vs messages
            HStack(spacing: 20) {
                chartCard("Tokens per Message (Efficiency)") {
                    tokensPerMessageChart
                }

                chartCard("Session Length vs Messages") {
                    sessionScatterPlot
                }
            }

            // Row 6: Cumulative cost + Avg session length over time
            HStack(spacing: 20) {
                chartCard("Cumulative Cost") {
                    cumulativeCostChart
                }

                chartCard("Avg Session Duration Over Time") {
                    avgDurationChart
                }
            }

            // Row 7: Authoritative per-model cost from stats-cache (full width)
            chartCard("Cost by Model (actual)") {
                costByModelChart
            }
        }
        .padding(20)
    }

    // MARK: - Chart Cards

    private func chartCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private func statCard(_ title: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).foregroundStyle(.purple)
            Text(value).font(.title2.weight(.bold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
    }

    // MARK: - Daily Cost Chart (with hover tooltip)

    private var dailyCostChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !dailyCost.isEmpty {
                Chart(dailyCost, id: \.date) { item in
                    LineMark(x: .value("Date", item.date, unit: .day), y: .value("Cost", item.cost))
                        .foregroundStyle(Color.green).interpolationMethod(.catmullRom)
                    AreaMark(x: .value("Date", item.date, unit: .day), y: .value("Cost", item.cost))
                        .foregroundStyle(Color.green.opacity(0.1).gradient).interpolationMethod(.catmullRom)

                    if let selected = selectedCostDate,
                       Calendar.current.isDate(item.date, inSameDayAs: selected) {
                        PointMark(x: .value("Date", item.date, unit: .day), y: .value("Cost", item.cost))
                            .foregroundStyle(Color.green).symbolSize(60)
                        RuleMark(x: .value("Date", item.date, unit: .day))
                            .foregroundStyle(Color.green.opacity(0.3)).lineStyle(StrokeStyle(dash: [4, 4]))
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text("$\(v.as(Double.self) ?? 0, specifier: "%.0f")") } } }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    let origin = geo[proxy.plotFrame!].origin
                                    if let date: Date = proxy.value(atX: loc.x - origin.x) {
                                        selectedCostDate = Calendar.current.startOfDay(for: date)
                                    }
                                case .ended: selectedCostDate = nil
                                }
                            }
                    }
                }
                .frame(height: 140)

                if let selected = selectedCostDate,
                   let dayData = dailyCost.first(where: { Calendar.current.isDate($0.date, inSameDayAs: selected) }) {
                    costTooltip(dayData)
                }
            }
        }
    }

    // MARK: - Hourly Heatmap

    private var hourlyHeatmap: some View {
        let hourData = computeHourlyData()
        let maxCount = hourData.map(\.count).max() ?? 1

        return VStack(alignment: .leading, spacing: 4) {
            // Grid: 4 rows x 6 columns
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 6), spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = hourData.first(where: { $0.hour == hour })?.count ?? 0
                    let intensity = maxCount > 0 ? Double(count) / Double(maxCount) : 0

                    RoundedRectangle(cornerRadius: 3)
                        .fill(intensity > 0 ? Color.purple.opacity(0.15 + intensity * 0.85) : Color.gray.opacity(0.08))
                        .frame(height: 28)
                        .overlay(
                            VStack(spacing: 0) {
                                Text("\(formatHour(hour))")
                                    .font(.system(size: 8))
                                    .foregroundStyle(intensity > 0.5 ? .white : .secondary)
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundStyle(intensity > 0.5 ? Color.white.opacity(0.8) : Color.gray.opacity(0.5))
                                }
                            }
                        )
                        .help("\(formatHour(hour)): \(count) sessions")
                }
            }
            .frame(height: 140)

            HStack {
                Text("Less").font(.system(size: 8)).foregroundStyle(.tertiary)
                ForEach([0.1, 0.3, 0.5, 0.7, 1.0], id: \.self) { v in
                    RoundedRectangle(cornerRadius: 2).fill(Color.purple.opacity(0.15 + v * 0.85)).frame(width: 12, height: 8)
                }
                Text("More").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Duration Histogram

    private var durationHistogram: some View {
        let buckets = computeDurationBuckets()
        return Group {
            if !buckets.isEmpty {
                Chart(buckets, id: \.label) { bucket in
                    BarMark(x: .value("Duration", bucket.label), y: .value("Count", bucket.count))
                        .foregroundStyle(Color.blue.gradient)
                        .cornerRadius(3)
                }
                .frame(height: 150)
            } else {
                Text("No duration data").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Cost per Project

    private var costPerProjectChart: some View {
        let projectCosts = computeProjectCosts()
        return Group {
            if !projectCosts.isEmpty {
                Chart(projectCosts.prefix(8), id: \.name) { item in
                    BarMark(x: .value("Cost", item.cost), y: .value("Project", item.name))
                        .foregroundStyle(Color.green.gradient)
                        .cornerRadius(3)
                }
                .chartXAxis { AxisMarks { v in AxisValueLabel { Text("$\(v.as(Double.self) ?? 0, specifier: "%.0f")") } } }
                .frame(height: 150)
            }
        }
    }

    // MARK: - Sessions per Project

    private var sessionsPerProjectChart: some View {
        let projectSessions = computeProjectSessions()
        return Group {
            if !projectSessions.isEmpty {
                Chart(projectSessions.prefix(8), id: \.name) { item in
                    BarMark(x: .value("Sessions", item.count), y: .value("Project", item.name))
                        .foregroundStyle(Color.purple.gradient)
                        .cornerRadius(3)
                }
                .frame(height: 150)
            }
        }
    }

    // MARK: - Lines per Project

    private var linesPerProjectChart: some View {
        let data = computeLinesPerProject()
        return Group {
            if !data.isEmpty {
                Chart(data.prefix(8), id: \.name) { item in
                    BarMark(x: .value("Added", item.added), y: .value("Project", item.name))
                        .foregroundStyle(Color.green)
                    BarMark(x: .value("Removed", item.removed), y: .value("Project", item.name))
                        .foregroundStyle(Color.red)
                }
                .frame(height: 150)
            }
        }
    }

    // MARK: - Tokens per Message

    private var tokensPerMessageChart: some View {
        let data = sessions.filter { $0.totalMessages > 0 }.prefix(15).map { s in
            (name: String(s.displayTitle.prefix(12)), ratio: Double(s.inputTokens + s.outputTokens) / Double(max(1, s.totalMessages)))
        }
        return Group {
            if !data.isEmpty {
                Chart(data, id: \.name) { item in
                    BarMark(x: .value("Session", item.name), y: .value("Tokens/Msg", item.ratio))
                        .foregroundStyle(Color.cyan.gradient)
                        .cornerRadius(3)
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .frame(height: 150)
            }
        }
    }

    // MARK: - Session Scatter Plot

    private var sessionScatterPlot: some View {
        let data = sessions.filter { $0.durationMinutes > 0 }
        return Group {
            if !data.isEmpty {
                Chart(data.prefix(50), id: \.sessionId) { s in
                    PointMark(
                        x: .value("Duration (min)", s.durationMinutes),
                        y: .value("Messages", s.totalMessages)
                    )
                    .foregroundStyle(Color.purple.opacity(0.6))
                    .symbolSize(30)
                }
                .chartXAxisLabel("Duration (min)")
                .chartYAxisLabel("Messages")
                .frame(height: 150)
            } else {
                Text("No duration data").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Cumulative Cost

    private var cumulativeCostChart: some View {
        let data = computeCumulativeCost()
        return Group {
            if !data.isEmpty {
                Chart(data, id: \.date) { item in
                    AreaMark(x: .value("Date", item.date, unit: .day), y: .value("Cost", item.cost))
                        .foregroundStyle(Color.orange.opacity(0.15).gradient)
                    LineMark(x: .value("Date", item.date, unit: .day), y: .value("Cost", item.cost))
                        .foregroundStyle(Color.orange)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartYAxis { AxisMarks { v in AxisValueLabel { Text("$\(v.as(Double.self) ?? 0, specifier: "%.0f")") } } }
                .frame(height: 150)
            }
        }
    }

    // MARK: - Cost by Model (authoritative)

    // Stats-cache stores a per-model token breakdown (input/output/cache-read/
    // cache-creation) but leaves `costUSD` at 0 in current Claude Code builds.
    // Compute cost ourselves using published Anthropic rates for the model's
    // family — more accurate than the Opus-flat-rate fallback used elsewhere.
    private var modelCosts: [ModelCostItem] {
        let path = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".claude/stats-cache.json")
        guard let data = FileManager.default.contents(atPath: path),
              let cache = try? JSONDecoder().decode(StatsCache.self, from: data) else { return [] }
        return cache.modelUsage
            .map { id, u in
                let rates = pricing(for: id)
                let cost =
                    Double(u.inputTokens) * rates.input / 1_000_000 +
                    Double(u.outputTokens) * rates.output / 1_000_000 +
                    Double(u.cacheReadInputTokens) * rates.cacheRead / 1_000_000 +
                    Double(u.cacheCreationInputTokens) * rates.cacheWrite / 1_000_000
                return ModelCostItem(model: prettyModelName(id), cost: cost)
            }
            .filter { $0.cost > 0 }
            .sorted { $0.cost > $1.cost }
    }

    private struct ModelCostItem { let model: String; let cost: Double }

    private struct ModelRates { let input: Double; let output: Double; let cacheRead: Double; let cacheWrite: Double }

    // $ per 1M tokens. Defaults to Opus pricing for unknown models.
    private func pricing(for modelId: String) -> ModelRates {
        let id = modelId.lowercased()
        if id.contains("haiku") {
            return ModelRates(input: 1.0, output: 5.0, cacheRead: 0.10, cacheWrite: 1.25)
        }
        if id.contains("sonnet") {
            return ModelRates(input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75)
        }
        // Opus (and fallback)
        return ModelRates(input: 15.0, output: 75.0, cacheRead: 1.50, cacheWrite: 18.75)
    }

    private func prettyModelName(_ id: String) -> String {
        // Convert "claude-opus-4-6-20251015" -> "Opus 4.6"
        let parts = id.split(separator: "-")
        guard parts.count >= 4 else { return id }
        let family = parts[1].capitalized
        let major = parts[2]
        let minor = parts[3]
        return "\(family) \(major).\(minor)"
    }

    private var costByModelChart: some View {
        let data = modelCosts
        let total = data.reduce(0) { $0 + $1.cost }
        return Group {
            if !data.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "Total: $%.2f", total))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart(data, id: \.model) { item in
                        BarMark(x: .value("Cost", item.cost), y: .value("Model", item.model))
                            .foregroundStyle(Color.green.gradient)
                            .cornerRadius(3)
                            .annotation(position: .trailing) {
                                Text(String(format: "$%.2f", item.cost))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis { AxisMarks { v in AxisValueLabel { Text("$\(v.as(Double.self) ?? 0, specifier: "%.0f")") } } }
                    .frame(height: max(80, CGFloat(data.count) * 32))
                }
            } else {
                Text("No model cost data in stats-cache.json").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Avg Session Duration Over Time

    private var avgDurationChart: some View {
        let data = computeAvgDuration()
        return Group {
            if !data.isEmpty {
                Chart(data, id: \.date) { item in
                    LineMark(x: .value("Date", item.date, unit: .day), y: .value("Avg Min", item.avgMinutes))
                        .foregroundStyle(Color.blue)
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Date", item.date, unit: .day), y: .value("Avg Min", item.avgMinutes))
                        .foregroundStyle(Color.blue)
                        .symbolSize(20)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartYAxisLabel("Minutes")
                .frame(height: 150)
            }
        }
    }

    // MARK: - Cost Tooltip

    private func costTooltip(_ dayData: DailyCostItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formatDay(dayData.date)).font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "$%.2f total", dayData.cost))
                    .font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(.green)
            }
            ForEach(dayData.sessions.prefix(5), id: \.sessionId) { session in
                Button(action: { onSelectSession?(session) }) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.green.opacity(0.5)).frame(width: 6, height: 6)
                        Text(String(session.displayTitle.prefix(40))).font(.caption2).lineLimit(1).foregroundStyle(.primary)
                        Spacer()
                        Text(String(format: "$%.2f", session.estimatedCost)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if dayData.sessions.count > 5 {
                Text("+\(dayData.sessions.count - 5) more").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.1)))
    }

    // MARK: - Data Computation

    private struct DailyCount { let date: Date; let count: Int }
    private struct DailyCostItem { let date: Date; let cost: Double; let sessions: [SessionInfo] }
    private struct ToolCount { let name: String; let count: Int }
    private struct HourCount { let hour: Int; let count: Int }
    private struct DurationBucket { let label: String; let count: Int }
    private struct ProjectCost { let name: String; let cost: Double }
    private struct ProjectCount { let name: String; let count: Int }
    private struct ProjectLines { let name: String; let added: Int; let removed: Int }
    private struct CumulativeCostItem { let date: Date; let cost: Double }
    private struct AvgDurationItem { let date: Date; let avgMinutes: Double }

    private var dailyData: [DailyCount] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.startTime) }
        return grouped.map { DailyCount(date: $0.key, count: $0.value.count) }.sorted { $0.date < $1.date }.suffix(30).map { $0 }
    }

    private var dailyCost: [DailyCostItem] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.startTime) }
        return grouped.map { DailyCostItem(date: $0.key, cost: $0.value.reduce(0) { $0 + $1.estimatedCost }, sessions: $0.value.sorted { $0.estimatedCost > $1.estimatedCost }) }
            .sorted { $0.date < $1.date }.suffix(30).map { $0 }
    }

    private var topTools: [ToolCount] {
        var totals: [String: Int] = [:]
        for s in sessions { for (tool, count) in s.toolCounts { totals[tool, default: 0] += count } }
        return totals.map { ToolCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }.prefix(8).map { $0 }
    }

    private func computeHourlyData() -> [HourCount] {
        let cal = Calendar.current
        var counts = [Int: Int]()
        for s in sessions { let h = cal.component(.hour, from: s.startTime); counts[h, default: 0] += 1 }
        return (0..<24).map { HourCount(hour: $0, count: counts[$0] ?? 0) }
    }

    private func computeDurationBuckets() -> [DurationBucket] {
        let durations = sessions.map(\.durationMinutes).filter { $0 > 0 }
        guard !durations.isEmpty else { return [] }
        let buckets: [(String, ClosedRange<Int>)] = [
            ("<5m", 0...4), ("5-15m", 5...15), ("15-30m", 16...30),
            ("30-60m", 31...60), ("1-2h", 61...120), ("2h+", 121...9999)
        ]
        return buckets.map { label, range in
            DurationBucket(label: label, count: durations.filter { range.contains($0) }.count)
        }.filter { $0.count > 0 }
    }

    private func computeProjectCosts() -> [ProjectCost] {
        var costs: [String: Double] = [:]
        for s in sessions { costs[s.projectName, default: 0] += s.estimatedCost }
        return costs.map { ProjectCost(name: $0.key, cost: $0.value) }.sorted { $0.cost > $1.cost }
    }

    private func computeProjectSessions() -> [ProjectCount] {
        var counts: [String: Int] = [:]
        for s in sessions { counts[s.projectName, default: 0] += 1 }
        return counts.map { ProjectCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    private func computeLinesPerProject() -> [ProjectLines] {
        var added: [String: Int] = [:]; var removed: [String: Int] = [:]
        for s in sessions { added[s.projectName, default: 0] += s.linesAdded; removed[s.projectName, default: 0] += s.linesRemoved }
        return added.keys.map { ProjectLines(name: $0, added: added[$0] ?? 0, removed: removed[$0] ?? 0) }
            .sorted { ($0.added + $0.removed) > ($1.added + $1.removed) }
    }

    private func computeCumulativeCost() -> [CumulativeCostItem] {
        let sorted = dailyCost.sorted { $0.date < $1.date }
        var cumulative = 0.0
        return sorted.map { cumulative += $0.cost; return CumulativeCostItem(date: $0.date, cost: cumulative) }
    }

    private func computeAvgDuration() -> [AvgDurationItem] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: sessions.filter { $0.durationMinutes > 0 }) { cal.startOfDay(for: $0.startTime) }
        return grouped.map { date, sessions in
            AvgDurationItem(date: date, avgMinutes: Double(sessions.reduce(0) { $0 + $1.durationMinutes }) / Double(sessions.count))
        }.sorted { $0.date < $1.date }.suffix(30).map { $0 }
    }

    // MARK: - Helpers

    private func formatDay(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: date)
    }

    private func formatHour(_ hour: Int) -> String {
        if hour == 0 { return "12a" }
        if hour < 12 { return "\(hour)a" }
        if hour == 12 { return "12p" }
        return "\(hour - 12)p"
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
