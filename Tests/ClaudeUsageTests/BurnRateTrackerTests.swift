import XCTest
@testable import ClaudeUsage

final class BurnRateTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ pct: Double, resetsIn seconds: TimeInterval = 4 * 3600) -> RateWindow {
        RateWindow(usedPercentage: pct, resetsAt: Int(t0.addingTimeInterval(seconds).timeIntervalSince1970))
    }

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func testNoSamplesGivesNothing() {
        let snap = BurnRateTracker().snapshot(at: t0, fiveHour: nil)
        XCTAssertEqual(snap, .init(percentPerHour: nil, costPerHour: nil, limitAt: nil, projectedAtReset: nil))
    }

    func testSpanTooShortGivesNil() {
        var tracker = BurnRateTracker()
        tracker.record(at: at(0), fiveHour: window(10), sessionCosts: ["s": 1])
        tracker.record(at: at(2), fiveHour: window(20), sessionCosts: ["s": 2])
        let snap = tracker.snapshot(at: at(2), fiveHour: window(20))
        XCTAssertNil(snap.percentPerHour)
        XCTAssertNil(snap.costPerHour)
    }

    func testSteadyPaceAndLimitEta() throws {
        var tracker = BurnRateTracker()
        // 10% and $1 every 10 minutes: 60%/h and $6/h
        for i in 0...3 {
            tracker.record(at: at(Double(i * 10)), fiveHour: window(40 + Double(i * 10)), sessionCosts: ["s": Double(i)])
        }
        let snap = tracker.snapshot(at: at(30), fiveHour: window(70))
        XCTAssertEqual(try XCTUnwrap(snap.percentPerHour), 60, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snap.costPerHour), 6, accuracy: 0.001)
        // 30% left at 60%/h is 30 minutes after the last sample
        XCTAssertEqual(try XCTUnwrap(snap.limitAt).timeIntervalSince(at(30)), 30 * 60, accuracy: 1)
        // 70% plus 60%/h for the 3.5h left until reset
        XCTAssertEqual(try XCTUnwrap(snap.projectedAtReset), 280, accuracy: 0.1)
    }

    func testProjectionUnderLimit() throws {
        var tracker = BurnRateTracker()
        // 2% per 10 minutes is 12%/h; 4h to reset from 22% gives 70%
        tracker.record(at: at(0), fiveHour: window(20, resetsIn: 4 * 3600 + 600), sessionCosts: [:])
        tracker.record(at: at(10), fiveHour: window(22, resetsIn: 4 * 3600 + 600), sessionCosts: [:])
        let snap = tracker.snapshot(at: at(10), fiveHour: window(22, resetsIn: 4 * 3600 + 600))
        XCTAssertEqual(try XCTUnwrap(snap.projectedAtReset), 70, accuracy: 0.1)
        XCTAssertNil(snap.limitAt)
    }

    func testNoLimitEtaWhenResetComesFirst() {
        var tracker = BurnRateTracker()
        tracker.record(at: at(0), fiveHour: window(10, resetsIn: 3600), sessionCosts: [:])
        tracker.record(at: at(10), fiveHour: window(12, resetsIn: 3600), sessionCosts: [:])
        let snap = tracker.snapshot(at: at(10), fiveHour: window(12, resetsIn: 3600))
        XCTAssertNotNil(snap.percentPerHour)
        XCTAssertNil(snap.limitAt)
    }

    func testNewWindowClearsPercentSamples() {
        var tracker = BurnRateTracker()
        tracker.record(at: at(0), fiveHour: window(90), sessionCosts: [:])
        // Window reset: new reset time far from the old one, usage back to 1%
        let fresh = RateWindow(usedPercentage: 1, resetsAt: Int(at(10 + 300).timeIntervalSince1970))
        tracker.record(at: at(10), fiveHour: fresh, sessionCosts: [:])
        XCTAssertNil(tracker.snapshot(at: at(10), fiveHour: fresh).percentPerHour)
    }

    func testSmallResetJitterKeepsSamples() {
        var tracker = BurnRateTracker()
        tracker.record(at: at(0), fiveHour: window(10), sessionCosts: [:])
        let jittered = RateWindow(usedPercentage: 20, resetsAt: Int(t0.addingTimeInterval(4 * 3600 + 30).timeIntervalSince1970))
        tracker.record(at: at(10), fiveHour: jittered, sessionCosts: [:])
        XCTAssertNotNil(tracker.snapshot(at: at(10), fiveHour: jittered).percentPerHour)
    }

    func testDecreasingPercentClampsToZero() {
        var tracker = BurnRateTracker()
        tracker.record(at: at(0), fiveHour: window(50), sessionCosts: [:])
        tracker.record(at: at(10), fiveHour: window(45), sessionCosts: [:])
        let snap = tracker.snapshot(at: at(10), fiveHour: window(45))
        XCTAssertEqual(snap.percentPerHour, 0)
        XCTAssertNil(snap.limitAt)
        XCTAssertEqual(snap.projectedAtReset, 45)
    }

    func testSessionCostBaselinesAndEndedSessions() throws {
        var tracker = BurnRateTracker()
        // An existing $50 session is only a baseline, not $50 of new spend
        tracker.record(at: at(0), fiveHour: nil, sessionCosts: ["old": 50])
        // A new session appears with $3 already spent: also a baseline
        tracker.record(at: at(5), fiveHour: nil, sessionCosts: ["old": 51, "new": 3])
        // The old session ends; its last cost must not be subtracted
        tracker.record(at: at(10), fiveHour: nil, sessionCosts: ["new": 4])
        // A cost that goes down (session restarted) is not negative spend
        tracker.record(at: at(15), fiveHour: nil, sessionCosts: ["new": 1])
        let cost = try XCTUnwrap(tracker.snapshot(at: at(15), fiveHour: nil).costPerHour)
        // $2 of real spend over 15 minutes
        XCTAssertEqual(cost, 8, accuracy: 0.001)
    }

    func testOldSamplesFallOutOfWindow() throws {
        var tracker = BurnRateTracker(window: 30 * 60)
        // Fast early burn, then idle for longer than the window
        tracker.record(at: at(0), fiveHour: window(10), sessionCosts: ["s": 0])
        tracker.record(at: at(5), fiveHour: window(40), sessionCosts: ["s": 10])
        tracker.record(at: at(40), fiveHour: window(40), sessionCosts: ["s": 10])
        tracker.record(at: at(50), fiveHour: window(40), sessionCosts: ["s": 10])
        let snap = tracker.snapshot(at: at(50), fiveHour: window(40))
        XCTAssertEqual(snap.percentPerHour, 0)
        XCTAssertEqual(snap.costPerHour, 0)
    }

    func testClockGoingBackwardsResets() {
        var tracker = BurnRateTracker()
        tracker.record(at: at(10), fiveHour: window(10), sessionCosts: ["s": 1])
        tracker.record(at: at(20), fiveHour: window(20), sessionCosts: ["s": 2])
        tracker.record(at: at(0), fiveHour: window(25), sessionCosts: ["s": 3])
        let snap = tracker.snapshot(at: at(0), fiveHour: window(25))
        XCTAssertNil(snap.percentPerHour)
        XCTAssertNil(snap.costPerHour)
    }

    func testExpiredWindowIsIgnored() {
        var tracker = BurnRateTracker()
        let expired = window(99, resetsIn: -60)
        tracker.record(at: at(0), fiveHour: expired, sessionCosts: [:])
        tracker.record(at: at(10), fiveHour: expired, sessionCosts: [:])
        XCTAssertNil(tracker.snapshot(at: at(10), fiveHour: expired).percentPerHour)
    }
}
