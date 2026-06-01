import SwiftUI

// A single API call extracted from a transcript JSONL line. One transcript
// entry with a `message.usage` block becomes one Invocation row.
struct Invocation: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let sessionId: String
    let projectName: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheRead: Int
    let cacheWrite: Int

    // Opus rates by default. For known models, swap in the right rate.
    var cost: Double {
        let rates = pricing(for: model)
        return Double(inputTokens) * rates.input / 1_000_000 +
               Double(outputTokens) * rates.output / 1_000_000 +
               Double(cacheRead) * rates.cacheRead / 1_000_000 +
               Double(cacheWrite) * rates.cacheWrite / 1_000_000
    }
}

private func pricing(for model: String) -> (input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
    let id = model.lowercased()
    if id.contains("haiku") { return (1.0, 5.0, 0.10, 1.25) }
    if id.contains("sonnet") { return (3.0, 15.0, 0.30, 3.75) }
    return (15.0, 75.0, 1.50, 18.75)
}

struct InvocationsView: View {
    let sessions: [SessionInfo]
    @State private var invocations: [Invocation] = []
    @State private var isLoading = false
    @State private var sortOrder: [KeyPathComparator<Invocation>] = [
        .init(\.timestamp, order: .reverse)
    ]
    @State private var modelFilter: String? = nil
    @State private var sessionFilter: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header

            if isLoading {
                VStack { Spacer(); ProgressView("Scanning transcripts..."); Spacer() }
            } else {
                Table(filtered, sortOrder: $sortOrder) {
                    TableColumn("Time", value: \.timestamp) { inv in
                        Text(formatDate(inv.timestamp)).font(.system(.body, design: .monospaced))
                    }
                    .width(min: 170, ideal: 190)

                    TableColumn("Model", value: \.model) { inv in
                        Text(inv.model).font(.system(.body, design: .monospaced))
                    }
                    .width(min: 180, ideal: 220)

                    TableColumn("Project", value: \.projectName) { inv in
                        Text(inv.projectName).foregroundStyle(.secondary)
                    }
                    .width(min: 150, ideal: 180)

                    TableColumn("In", value: \.inputTokens) { inv in
                        Text(numberFormat(inv.inputTokens))
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(60)

                    TableColumn("Out", value: \.outputTokens) { inv in
                        Text(numberFormat(inv.outputTokens))
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(70)

                    TableColumn("Cache Write", value: \.cacheWrite) { inv in
                        Text(inv.cacheWrite == 0 ? "—" : numberFormat(inv.cacheWrite))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(inv.cacheWrite == 0 ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(90)

                    TableColumn("Cache Read", value: \.cacheRead) { inv in
                        Text(inv.cacheRead == 0 ? "—" : numberFormat(inv.cacheRead))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(inv.cacheRead == 0 ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(100)

                    TableColumn("Cost", value: \.cost) { inv in
                        Text(String(format: "$%.4f", inv.cost))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(80)
                }
            }
        }
        .onAppear(perform: loadInvocations)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Recent Invocations")
                .font(.title3.weight(.semibold))

            Spacer()

            if !invocations.isEmpty {
                Text("\(filtered.count) invocations · \(String(format: "$%.2f", filtered.reduce(0) { $0 + $1.cost })) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu(modelFilter ?? "All Models") {
                Button("All Models") { modelFilter = nil }
                ForEach(uniqueModels, id: \.self) { m in
                    Button(m) { modelFilter = m }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var filtered: [Invocation] {
        var items = invocations
        if let m = modelFilter { items = items.filter { $0.model == m } }
        if let s = sessionFilter { items = items.filter { $0.sessionId == s } }
        return items.sorted(using: sortOrder)
    }

    private var uniqueModels: [String] {
        Array(Set(invocations.map(\.model))).sorted()
    }

    private func loadInvocations() {
        guard invocations.isEmpty else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let all = sessions.flatMap { parseTranscript(session: $0) }
            let sorted = all.sorted { $0.timestamp > $1.timestamp }
            DispatchQueue.main.async {
                self.invocations = sorted
                self.isLoading = false
            }
        }
    }

    private func parseTranscript(session: SessionInfo) -> [Invocation] {
        guard let path = session.transcriptPath,
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var out: [Invocation] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let msg = json["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }

            let tsString = json["timestamp"] as? String ?? ""
            let timestamp = iso.date(from: tsString) ?? session.startTime
            let model = (msg["model"] as? String) ?? "unknown"

            let inv = Invocation(
                timestamp: timestamp,
                sessionId: session.sessionId,
                projectName: session.projectName,
                model: model,
                inputTokens: (usage["input_tokens"] as? Int) ?? 0,
                outputTokens: (usage["output_tokens"] as? Int) ?? 0,
                cacheRead: (usage["cache_read_input_tokens"] as? Int) ?? 0,
                cacheWrite: (usage["cache_creation_input_tokens"] as? Int) ?? 0
            )
            out.append(inv)
        }
        return out
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy, h:mm:ss a"
        return f.string(from: d)
    }

    private func numberFormat(_ n: Int) -> String {
        if n == 0 { return "0" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
