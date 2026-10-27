import XCTest
@testable import ClaudeUsage

final class TranscriptUsageScannerTests: TranscriptTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testPerDayPerModelAndDedupe() throws {
        let text = [
            Lines.user,
            Lines.assistant(id: "a", timestamp: "2026-10-26T23:00:00.000Z"),
            Lines.assistant(id: "a", timestamp: "2026-10-26T23:00:00.000Z"),
            Lines.assistant(id: "b", model: "claude-sonnet-5-5", timestamp: "2026-10-27T01:00:00.000Z"),
            Lines.toolResult,
        ].joined(separator: "\n") + "\n"
        let path = try write(text)
        let usage = TranscriptUsageScanner(timeZone: utc).usage(atPath: path)

        let one = DayTokens(input: 10, output: 20, cacheRead: 900, cacheCreate: 90)
        XCTAssertEqual(usage.total, DayTokens(input: 20, output: 40, cacheRead: 1800, cacheCreate: 180))
        XCTAssertEqual(usage.perDay, ["2026-10-26": one, "2026-10-27": one])
        XCTAssertEqual(usage.perModel, ["claude-opus-5-5": one, "claude-sonnet-5-5": one])
    }

    func testSameIdNonConsecutiveIsCountedAgain() throws {
        // Dedupe relies on repeats being consecutive, which is how Claude Code
        // writes them; an interleaved id is treated as a new response
        let text = [Lines.assistant(id: "a"), Lines.assistant(id: "b"), Lines.assistant(id: "a")].joined(separator: "\n") + "\n"
        let path = try write(text)
        XCTAssertEqual(TranscriptUsageScanner().usage(atPath: path).total.input, 30)
    }

    func testMissingTimestampAndModelBinToUnknown() throws {
        let line = #"{"type":"assistant","message":{"usage":{"input_tokens":5}}}"#
        let path = try write(line + "\n")
        let usage = TranscriptUsageScanner().usage(atPath: path)
        XCTAssertEqual(usage.perDay["unknown"]?.input, 5)
        XCTAssertEqual(usage.perModel["unknown"]?.input, 5)
    }

    func testEmptyMissingAndMalformed() throws {
        let scanner = TranscriptUsageScanner()
        XCTAssertEqual(scanner.usage(atPath: try write("", to: "empty.jsonl")), .init())
        XCTAssertEqual(scanner.usage(atPath: dir.appendingPathComponent("nope.jsonl").path), .init())
        // A line mentioning "usage" that isn't valid JSON is skipped, not fatal
        let path = try write(#"{"usage": broken"# + "\n" + Lines.assistant(id: "a") + "\n", to: "bad.jsonl")
        XCTAssertEqual(scanner.usage(atPath: path).total.input, 10)
    }

    func testChunkSizeDoesNotChangeResult() throws {
        let text = (0..<20).map { Lines.assistant(id: "m\($0 / 2)") }.joined(separator: "\n") + "\n"
        let path = try write(text)
        let expected = TranscriptUsageScanner(timeZone: utc).usage(atPath: path)
        XCTAssertEqual(expected.total.input, 100)
        for chunk in [1, 13, 4096] {
            XCTAssertEqual(TranscriptUsageScanner(chunkSize: chunk, timeZone: utc).usage(atPath: path), expected, "chunk \(chunk)")
        }
    }

    func testIncrementalGrowthAndTruncation() throws {
        let scanner = TranscriptUsageScanner()
        let path = try write(Lines.assistant(id: "a") + "\n")
        XCTAssertEqual(scanner.usage(atPath: path).total.input, 10)
        XCTAssertEqual(scanner.usage(atPath: path).total.input, 10, "unchanged file must not double count")
        try append(Lines.assistant(id: "a") + "\n" + Lines.assistant(id: "b") + "\n", to: path)
        XCTAssertEqual(scanner.usage(atPath: path).total.input, 20)
        _ = try write(Lines.assistant(id: "z", input: 7) + "\n")
        XCTAssertEqual(scanner.usage(atPath: path).total.input, 7)
    }
}
