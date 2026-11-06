import XCTest
@testable import ClaudeUsage

final class ModelUsageTotalsTests: TranscriptTestCase {
    private func usage(_ input: Int, _ output: Int, cost: Double = 0) -> ModelUsage {
        ModelUsage(inputTokens: input, outputTokens: output, cacheReadInputTokens: 0,
                   cacheCreationInputTokens: 0, webSearchRequests: 0, costUSD: cost)
    }

    func testMergeTakesLargerSourcePerModel() {
        let merged = ModelUsageTotals.merge(
            stats: ["old": usage(10, 1000, cost: 5), "both": usage(1, 1)],
            transcripts: ["both": DayTokens(input: 50, output: 50), "new": DayTokens(input: 7, output: 3)]
        )
        // Stale cache wins for a model whose transcripts were cleaned up
        XCTAssertEqual(merged["old"]?.outputTokens, 1000)
        XCTAssertEqual(merged["old"]?.costUSD, 5)
        // Transcripts win when the cache stopped counting
        XCTAssertEqual(merged["both"]?.outputTokens, 50)
        // A model the cache never saw still shows up
        XCTAssertEqual(merged["new"]?.inputTokens, 7)
    }

    func testMergeTieKeepsStatsAndEmptyInputs() {
        XCTAssertTrue(ModelUsageTotals.merge(stats: [:], transcripts: [:]).isEmpty)
        let merged = ModelUsageTotals.merge(stats: ["m": usage(5, 5, cost: 1)], transcripts: ["m": DayTokens(input: 5, output: 5)])
        XCTAssertEqual(merged["m"]?.costUSD, 1)
    }

    func testMergeDropsUnknownAndSyntheticModels() {
        let merged = ModelUsageTotals.merge(
            stats: [:],
            transcripts: ["unknown": DayTokens(input: 1), "<synthetic>": DayTokens(input: 1), "claude-opus-5-5": DayTokens(input: 1)]
        )
        XCTAssertEqual(Array(merged.keys), ["claude-opus-5-5"])
    }

    func testTranscriptTotalsWalkSubdirectoriesAndThrottle() throws {
        let sub = dir.appendingPathComponent("proj/session/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try write(Lines.assistant(id: "a") + "\n", to: "proj/main.jsonl")
        _ = try write(Lines.assistant(id: "b", model: "claude-fable-5-1") + "\n", to: "proj/session/subagents/agent.jsonl")
        _ = try write(Lines.assistant(id: "c") + "\n", to: "proj/notes.txt")

        let totals = ModelUsageTotals(projectsDir: dir.path, minInterval: 60)
        let start = Date()
        let first = totals.transcriptTotals(now: start)
        XCTAssertEqual(first["claude-opus-5-5"]?.input, 10, "non-jsonl files are ignored")
        XCTAssertEqual(first["claude-fable-5-1"]?.input, 10, "subagent transcripts count")

        try append(Lines.assistant(id: "d") + "\n", to: dir.appendingPathComponent("proj/main.jsonl").path)
        XCTAssertEqual(totals.transcriptTotals(now: start.addingTimeInterval(30))["claude-opus-5-5"]?.input, 10, "throttled")
        XCTAssertEqual(totals.transcriptTotals(now: start.addingTimeInterval(61))["claude-opus-5-5"]?.input, 20)
    }

    func testModelNameShort() {
        XCTAssertEqual(ModelName.short("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelName.short("claude-fable-5"), "Fable 5")
        XCTAssertEqual(ModelName.short("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelName.short("claude-sonnet-4-20250514"), "Sonnet 4")
        XCTAssertEqual(ModelName.short("anthropic.Polaris.Model.Smart.High"), "anthropic.Polaris.Model.Smart.High")
        XCTAssertEqual(ModelName.short("claude-instant"), "claude-instant")
        XCTAssertEqual(ModelName.short(""), "")
    }
}
