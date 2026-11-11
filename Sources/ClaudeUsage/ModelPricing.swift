import Foundation

// $ per 1M tokens
struct ModelRates: Equatable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double

    func cost(_ t: DayTokens) -> Double {
        (Double(t.input) * input + Double(t.output) * output +
         Double(t.cacheRead) * cacheRead + Double(t.cacheCreate) * cacheWrite) / 1_000_000
    }
}

enum ModelPricing {
    // Opus 4.5 through Opus 5. Also the fallback for unknown models.
    static let opus = ModelRates(input: 5.0, output: 25.0, cacheRead: 0.50, cacheWrite: 6.25)
    // Opus 5.5 cut cache reads to 0.05x input
    static let opus55 = ModelRates(input: 4.0, output: 20.0, cacheRead: 0.20, cacheWrite: 5.00)
    // Claude 3 Opus, Opus 4 and Opus 4.1
    static let opusLegacy = ModelRates(input: 15.0, output: 75.0, cacheRead: 1.50, cacheWrite: 18.75)
    static let sonnet = ModelRates(input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75)
    static let haiku = ModelRates(input: 1.0, output: 5.0, cacheRead: 0.10, cacheWrite: 1.25)
    // Fable 5 and 5.1 share per-token prices; 5.1 cut cache reads to a
    // quarter. Cache writes are the standard 1.25x input.
    static let fable5 = ModelRates(input: 10.0, output: 50.0, cacheRead: 1.00, cacheWrite: 12.50)
    static let fable51 = ModelRates(input: 10.0, output: 50.0, cacheRead: 0.25, cacheWrite: 12.50)
    static let fable52 = ModelRates(input: 8.0, output: 40.0, cacheRead: 0.20, cacheWrite: 10.00)

    /// Defaults to current Opus rates for unknown models. Mythos is priced as
    /// the Fable release of the same version.
    static func rates(for modelId: String) -> ModelRates {
        let id = modelId.lowercased()
        if id.contains("opus") {
            if id.contains("opus-5-5") { return opus55 }
            // "claude-opus-4-1-...", "claude-opus-4-0", "claude-opus-4-20250514", "claude-3-opus-..."
            if id.contains("3-opus") || id.contains("opus-4-1") || id.contains("opus-4-0")
                || id.range(of: #"opus-4-\d{8}"#, options: .regularExpression) != nil {
                return opusLegacy
            }
            return opus
        }
        if id.contains("haiku") { return haiku }
        if id.contains("sonnet") { return sonnet }
        if id.contains("fable") || id.contains("mythos") {
            if id.contains("-5-1") { return fable51 }
            if id.hasSuffix("fable-5") || id.hasSuffix("mythos-5") { return fable5 }
            // 5.2 and any newer release: the latest known prices
            return fable52
        }
        return opus
    }
}

extension SessionInfo {
    /// Cost per "yyyy-MM-dd" day, priced per model when the per-model
    /// breakdown exists, otherwise at current Opus rates.
    var dailyCost: [String: Double] {
        var costs: [String: Double] = [:]
        if !modelDailyTokens.isEmpty {
            for (model, perDay) in modelDailyTokens {
                let rates = ModelPricing.rates(for: model)
                for (day, tokens) in perDay { costs[day, default: 0] += rates.cost(tokens) }
            }
        } else {
            for (day, tokens) in dailyTokens { costs[day] = tokens.estimatedCost }
        }
        return costs
    }
}
