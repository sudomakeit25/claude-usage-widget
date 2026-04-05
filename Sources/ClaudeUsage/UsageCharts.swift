import SwiftUI
import Charts

struct UsageChartsView: View {
    let sessions: [SessionInfo]
    @State private var selectedCostDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Usage Overview")
                .font(.headline)

            HStack(spacing: 20) {
                statCard("Total Sessions", value: "\(sessions.count)", icon: "terminal")
                statCard("Total Messages", value: formatNumber(sessions.reduce(0) { $0 + $1.totalMessages }), icon: "message")
                statCard("Total Tokens", value: formatTokens(sessions.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }), icon: "number")
                statCard("Est. API Cost", value: String(format: "$%.0f", sessions.reduce(0.0) { $0 + $1.estimatedCost }), icon: "dollarsign.circle")
            }

            HStack(spacing: 20) {
                // Daily activity chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("Daily Sessions")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    if !dailyData.isEmpty {
                        Chart(dailyData, id: \.date) { item in
                            BarMark(
                                x: .value("Date", item.date, unit: .day),
                                y: .value("Sessions", item.count)
                            )
                            .foregroundStyle(Color.purple.gradient)
                            .cornerRadius(3)
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            }
                        }
                        .frame(height: 150)
                    } else {
                        Text("No data").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)

                // Messages per session chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("Messages per Session")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    if !recentSessions.isEmpty {
                        Chart(recentSessions, id: \.sessionId) { session in
                            BarMark(
                                x: .value("Session", String(session.displayTitle.prefix(15))),
                                y: .value("Messages", session.totalMessages)
                            )
                            .foregroundStyle(Color.blue.gradient)
                            .cornerRadius(3)
                        }
                        .chartXAxis {
                            AxisMarks { _ in
                                AxisValueLabel()
                                    .font(.caption2)
                            }
                        }
                        .frame(height: 150)
                    } else {
                        Text("No data").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 20) {
                // Tool usage breakdown
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top Tools Used")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    if !topTools.isEmpty {
                        Chart(topTools, id: \.name) { tool in
                            BarMark(
                                x: .value("Count", tool.count),
                                y: .value("Tool", tool.name)
                            )
                            .foregroundStyle(Color.orange.gradient)
                            .cornerRadius(3)
                        }
                        .frame(height: 150)
                    }
                }
                .frame(maxWidth: .infinity)

                // Cost over time
                VStack(alignment: .leading, spacing: 8) {
                    Text("Daily Cost (API equiv.)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    if !dailyCost.isEmpty {
                        Chart(dailyCost, id: \.date) { item in
                            LineMark(
                                x: .value("Date", item.date, unit: .day),
                                y: .value("Cost", item.cost)
                            )
                            .foregroundStyle(Color.green)
                            .interpolationMethod(.catmullRom)

                            AreaMark(
                                x: .value("Date", item.date, unit: .day),
                                y: .value("Cost", item.cost)
                            )
                            .foregroundStyle(Color.green.opacity(0.1).gradient)
                            .interpolationMethod(.catmullRom)

                            if let selected = selectedCostDate,
                               Calendar.current.isDate(item.date, inSameDayAs: selected) {
                                PointMark(
                                    x: .value("Date", item.date, unit: .day),
                                    y: .value("Cost", item.cost)
                                )
                                .foregroundStyle(Color.green)
                                .symbolSize(60)

                                RuleMark(x: .value("Date", item.date, unit: .day))
                                    .foregroundStyle(Color.green.opacity(0.3))
                                    .lineStyle(StrokeStyle(dash: [4, 4]))
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            }
                        }
                        .chartYAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    Text("$\(value.as(Double.self) ?? 0, specifier: "%.0f")")
                                }
                            }
                        }
                        .chartOverlay { proxy in
                            GeometryReader { geo in
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let location):
                                            let origin = geo[proxy.plotFrame!].origin
                                            let x = location.x - origin.x
                                            if let date: Date = proxy.value(atX: x) {
                                                selectedCostDate = Calendar.current.startOfDay(for: date)
                                            }
                                        case .ended:
                                            selectedCostDate = nil
                                        }
                                    }
                            }
                        }
                        .frame(height: 150)

                        // Tooltip showing sessions for selected date
                        if let selected = selectedCostDate,
                           let dayData = dailyCost.first(where: { Calendar.current.isDate($0.date, inSameDayAs: selected) }) {
                            costTooltip(dayData)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
    }

    private func costTooltip(_ dayData: DailyCostItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formatDay(dayData.date))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "$%.2f total", dayData.cost))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.green)
            }

            ForEach(dayData.sessions.prefix(5), id: \.sessionId) { session in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(String(session.displayTitle.prefix(40)))
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "$%.2f", session.estimatedCost))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if dayData.sessions.count > 5 {
                Text("+\(dayData.sessions.count - 5) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.1)))
    }

    private func formatDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    private func statCard(_ title: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.purple)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
    }

    // MARK: - Data

    private struct DailyCount {
        let date: Date
        let count: Int
    }

    private struct DailyCostItem {
        let date: Date
        let cost: Double
        let sessions: [SessionInfo]
    }

    private struct ToolCount {
        let name: String
        let count: Int
    }

    private var dailyData: [DailyCount] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startTime) }
        return grouped.map { DailyCount(date: $0.key, count: $0.value.count) }
            .sorted { $0.date < $1.date }
            .suffix(30)
            .map { $0 }
    }

    private var dailyCost: [DailyCostItem] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startTime) }
        return grouped.map { DailyCostItem(date: $0.key, cost: $0.value.reduce(0) { $0 + $1.estimatedCost }, sessions: $0.value.sorted { $0.estimatedCost > $1.estimatedCost }) }
            .sorted { $0.date < $1.date }
            .suffix(30)
            .map { $0 }
    }

    private var recentSessions: [SessionInfo] {
        Array(sessions.prefix(10))
    }

    private var topTools: [ToolCount] {
        var totals: [String: Int] = [:]
        for session in sessions {
            for (tool, count) in session.toolCounts {
                totals[tool, default: 0] += count
            }
        }
        return totals.map { ToolCount(name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(8)
            .map { $0 }
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
