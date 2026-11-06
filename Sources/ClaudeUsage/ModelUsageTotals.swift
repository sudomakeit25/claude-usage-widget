import Foundation

// All-time token usage per model. stats-cache.json can stop updating for
// months, and transcripts older than cleanupPeriodDays are deleted, so
// neither source is complete alone: each model takes whichever is larger.
final class ModelUsageTotals {
    private let scanner = TranscriptUsageScanner()
    private let projectsDir: String
    private let minInterval: TimeInterval
    private var lastScan: Date?
    private var cached: [String: DayTokens] = [:]

    init(projectsDir: String, minInterval: TimeInterval = 60) {
        self.projectsDir = projectsDir
        self.minInterval = minInterval
    }

    /// Per-model totals across every transcript, subagents included. The
    /// scanner only reads new bytes, but walking ~1.6k files still costs
    /// ~0.4s, so this runs at most once per `minInterval`.
    func transcriptTotals(now: Date = Date()) -> [String: DayTokens] {
        if let last = lastScan, now.timeIntervalSince(last) < minInterval { return cached }
        var totals: [String: DayTokens] = [:]
        if let walker = FileManager.default.enumerator(atPath: projectsDir) {
            for case let rel as String in walker where rel.hasSuffix(".jsonl") {
                for (model, tokens) in scanner.usage(atPath: "\(projectsDir)/\(rel)").perModel {
                    totals[model, default: DayTokens()] += tokens
                }
            }
        }
        cached = totals
        lastScan = now
        return totals
    }

    static func merge(stats: [String: ModelUsage], transcripts: [String: DayTokens]) -> [String: ModelUsage] {
        var merged: [String: ModelUsage] = [:]
        for model in Set(stats.keys).union(transcripts.keys) where model != "unknown" && !model.hasPrefix("<") {
            let fromStats = stats[model]
            let fromTranscripts = transcripts[model].map {
                ModelUsage(inputTokens: $0.input, outputTokens: $0.output,
                           cacheReadInputTokens: $0.cacheRead, cacheCreationInputTokens: $0.cacheCreate,
                           webSearchRequests: 0, costUSD: 0)
            }
            switch (fromStats, fromTranscripts) {
            case let (s?, t?):
                merged[model] = t.inputTokens + t.outputTokens > s.inputTokens + s.outputTokens ? t : s
            case let (s?, nil): merged[model] = s
            case let (nil, t?): merged[model] = t
            case (nil, nil): break
            }
        }
        return merged
    }
}

enum ModelName {
    /// "claude-opus-4-6-20251015" -> "Opus 4.6", "claude-fable-5" -> "Fable 5".
    /// Ids that aren't claude-family-version (gateway names) come back as is.
    static func short(_ id: String) -> String {
        let parts = id.split(separator: "-")
        guard parts.count >= 3, parts[0] == "claude", parts[2].allSatisfy(\.isNumber) else { return id }
        let family = parts[1].capitalized
        // A date suffix is not a minor version
        if parts.count >= 4, parts[3].count <= 2, parts[3].allSatisfy(\.isNumber) {
            return "\(family) \(parts[2]).\(parts[3])"
        }
        return "\(family) \(parts[2])"
    }
}
