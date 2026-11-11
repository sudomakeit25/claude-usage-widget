import XCTest
@testable import ClaudeUsage

final class ModelPricingTests: XCTestCase {
    func testRatesPerModel() {
        XCTAssertEqual(ModelPricing.rates(for: "claude-fable-5"), ModelPricing.fable5)
        XCTAssertEqual(ModelPricing.rates(for: "claude-fable-5-1"), ModelPricing.fable51)
        XCTAssertEqual(ModelPricing.rates(for: "claude-fable-5-2"), ModelPricing.fable52)
        XCTAssertEqual(ModelPricing.rates(for: "claude-mythos-5-1"), ModelPricing.fable51)
        XCTAssertEqual(ModelPricing.rates(for: "CLAUDE-FABLE-5-1"), ModelPricing.fable51)
        XCTAssertEqual(ModelPricing.rates(for: "claude-haiku-4-5-20251001"), ModelPricing.haiku)
        XCTAssertEqual(ModelPricing.rates(for: "claude-sonnet-4-6"), ModelPricing.sonnet)
        XCTAssertEqual(ModelPricing.rates(for: "claude-opus-5-5"), ModelPricing.opus)
        // Unknown and empty ids fall back to Opus; an unreleased Fable gets the newest Fable rates
        XCTAssertEqual(ModelPricing.rates(for: "anthropic.Polaris.Model.Smart.High"), ModelPricing.opus)
        XCTAssertEqual(ModelPricing.rates(for: ""), ModelPricing.opus)
        XCTAssertEqual(ModelPricing.rates(for: "claude-fable-5-3"), ModelPricing.fable52)
    }

    func testCostUsesEveryTokenKind() {
        let t = DayTokens(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreate: 1_000_000)
        XCTAssertEqual(ModelPricing.fable52.cost(t), 8 + 40 + 0.20 + 10, accuracy: 1e-9)
        XCTAssertEqual(ModelPricing.fable5.cost(t), 10 + 50 + 1 + 12.5, accuracy: 1e-9)
        XCTAssertEqual(ModelPricing.fable51.cost(DayTokens()), 0)
    }

    private func session(model: [String: DayTokens] = [:], daily: [String: [String: DayTokens]] = [:],
                         dayTokens: [String: DayTokens] = [:], live: Double? = nil) -> SessionInfo {
        SessionInfo(sessionId: "s", projectPath: "/p", projectName: "p", startTime: Date(), durationMinutes: 0,
                    userMessageCount: 0, assistantMessageCount: 0, firstPrompt: "", toolCounts: [:],
                    inputTokens: 1_000_000, outputTokens: 0, dailyTokens: dayTokens, modelTokens: model,
                    modelDailyTokens: daily, linesAdded: 0, linesRemoved: 0, transcriptPath: nil, liveCostUsd: live)
    }

    func testSessionCostPricesEachModel() {
        let m = DayTokens(input: 1_000_000)
        XCTAssertEqual(session(model: ["claude-fable-5-1": m, "claude-opus-5-5": m]).estimatedCost, 10 + 15, accuracy: 1e-9)
        // No per-model data: whole session at Opus rates
        XCTAssertEqual(session().estimatedCost, 15, accuracy: 1e-9)
        // Live cost from Claude Code wins
        XCTAssertEqual(session(model: ["claude-fable-5-1": m], live: 3).estimatedCost, 3)
    }

    func testDailyCostSplitsByDayAndModel() {
        let m = DayTokens(input: 1_000_000)
        let s = session(daily: ["claude-fable-5-2": ["2026-11-01": m], "claude-opus-5-5": ["2026-11-01": m, "2026-11-02": m]],
                        dayTokens: ["2026-11-01": m, "2026-11-02": m])
        XCTAssertEqual(s.dailyCost["2026-11-01"] ?? 0, 8 + 15, accuracy: 1e-9)
        XCTAssertEqual(s.dailyCost["2026-11-02"] ?? 0, 15, accuracy: 1e-9)
        // Without the per-model breakdown, days fall back to Opus rates
        XCTAssertEqual(session(dayTokens: ["2026-11-01": m]).dailyCost, ["2026-11-01": 15])
        XCTAssertTrue(session().dailyCost.isEmpty)
    }
}
