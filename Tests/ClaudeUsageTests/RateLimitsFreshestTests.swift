import XCTest
@testable import ClaudeUsage

final class RateLimitsFreshestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var later: Int { Int(now.timeIntervalSince1970) + 3600 }
    private var earlier: Int { Int(now.timeIntervalSince1970) - 60 }

    private func limits(_ five: Double, _ seven: Double, fiveReset: Int? = nil, sevenReset: Int? = nil) -> RateLimits {
        RateLimits(fiveHour: RateWindow(usedPercentage: five, resetsAt: fiveReset ?? later),
                   sevenDay: RateWindow(usedPercentage: seven, resetsAt: sevenReset ?? later + 86400))
    }

    func testFresherStatuslineBeatsStalePoll() {
        // The reported case: poll says 62%, live sessions already at 72-73%
        let r = RateLimits.freshest(polled: limits(62, 50), statusline: [limits(73, 52), limits(62, 50), limits(72, 52)], now: now)
        XCTAssertEqual(r?.fiveHour.usedPercentage, 73)
        XCTAssertEqual(r?.sevenDay.usedPercentage, 52)
    }

    func testPollWinsWhenStatuslinesAreBehind() {
        // e.g. usage from claude.ai that no local session has seen yet
        let r = RateLimits.freshest(polled: limits(80, 60), statusline: [limits(70, 55)], now: now)
        XCTAssertEqual(r?.fiveHour.usedPercentage, 80)
        XCTAssertEqual(r?.sevenDay.usedPercentage, 60)
    }

    func testWindowsArePickedIndependently() {
        let r = RateLimits.freshest(polled: limits(40, 90), statusline: [limits(70, 30)], now: now)
        XCTAssertEqual(r?.fiveHour.usedPercentage, 70)
        XCTAssertEqual(r?.sevenDay.usedPercentage, 90)
    }

    func testExpiredWindowIgnoredWhileALiveOneExists() {
        // A session file left over from the previous 5h window must not win
        let r = RateLimits.freshest(polled: limits(5, 50), statusline: [limits(95, 50, fiveReset: earlier)], now: now)
        XCTAssertEqual(r?.fiveHour.usedPercentage, 5)
    }

    func testAllExpiredFallsBackToLatestWindow() {
        let r = RateLimits.freshest(polled: nil, statusline: [limits(95, 50, fiveReset: earlier - 100), limits(20, 50, fiveReset: earlier)], now: now)
        XCTAssertEqual(r?.fiveHour.resetsAt, earlier)
    }

    func testEmptyInputs() {
        XCTAssertNil(RateLimits.freshest(polled: nil, statusline: [], now: now))
        XCTAssertEqual(RateLimits.freshest(polled: limits(10, 20), statusline: [], now: now)?.fiveHour.usedPercentage, 10)
        XCTAssertEqual(RateLimits.freshest(polled: nil, statusline: [limits(30, 40)], now: now)?.sevenDay.usedPercentage, 40)
    }
}
