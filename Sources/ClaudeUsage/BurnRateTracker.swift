import Foundation

// Recent pace for the 5-hour limit and API-equivalent spend, from samples
// taken on each refresh. A rolling window reflects how fast usage is going
// right now, unlike RateWindow.projectionText which averages over the whole
// window since it started.
struct BurnRateTracker {
    struct Snapshot: Equatable {
        let percentPerHour: Double?
        let costPerHour: Double?
        /// When the 5-hour limit reaches 100% at the current pace, if before reset
        let limitAt: Date?
        /// Usage expected at reset if the current pace holds
        let projectedAtReset: Double?
    }

    private struct Sample {
        let time: Date
        let value: Double
    }

    private let window: TimeInterval
    private let minSpan: TimeInterval
    private var percentSamples: [Sample] = []
    private var windowResetsAt: Int?
    private var costSamples: [Sample] = []
    private var lastSessionCost: [String: Double] = [:]
    private var cumulativeCost = 0.0

    init(window: TimeInterval = 30 * 60, minSpan: TimeInterval = 5 * 60) {
        self.window = window
        self.minSpan = minSpan
    }

    mutating func record(at now: Date, fiveHour: RateWindow?, sessionCosts: [String: Double]) {
        // Clock went backwards: the samples can't be trusted
        if let last = costSamples.last, now < last.time {
            percentSamples = []
            costSamples = []
        }

        if let w = fiveHour, now < w.resetDate {
            // Statusline and API can report reset times a few seconds apart;
            // only a real jump means a new 5-hour window
            if let current = windowResetsAt, abs(current - w.resetsAt) > 300 {
                percentSamples = []
            }
            windowResetsAt = w.resetsAt
            percentSamples.append(Sample(time: now, value: w.usedPercentage))
        }

        // Accumulate cost increases per session. A session seen for the first
        // time only sets a baseline, and one that ended simply stops adding.
        var seen: [String: Double] = [:]
        for (id, cost) in sessionCosts {
            if let prev = lastSessionCost[id], cost > prev {
                cumulativeCost += cost - prev
            }
            seen[id] = cost
        }
        lastSessionCost = seen
        costSamples.append(Sample(time: now, value: cumulativeCost))

        let cutoff = now.addingTimeInterval(-window)
        percentSamples.removeAll { $0.time < cutoff }
        costSamples.removeAll { $0.time < cutoff }
    }

    func snapshot(at now: Date, fiveHour: RateWindow?) -> Snapshot {
        let percentRate = Self.perHour(percentSamples, minSpan: minSpan)
        var limitAt: Date?
        var projected: Double?
        if let rate = percentRate, let w = fiveHour, now < w.resetDate {
            projected = w.usedPercentage + rate * w.resetDate.timeIntervalSince(now) / 3600
            if rate > 0, w.usedPercentage < 100 {
                let eta = now.addingTimeInterval((100 - w.usedPercentage) / rate * 3600)
                if eta < w.resetDate { limitAt = eta }
            }
        }
        return Snapshot(
            percentPerHour: percentRate,
            costPerHour: Self.perHour(costSamples, minSpan: minSpan),
            limitAt: limitAt,
            projectedAtReset: projected
        )
    }

    // Change per hour across the samples, or nil if they span too little time
    private static func perHour(_ samples: [Sample], minSpan: TimeInterval) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        guard span >= minSpan else { return nil }
        return max(0, (last.value - first.value) / span * 3600)
    }
}
