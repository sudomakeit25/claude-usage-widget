import XCTest
@testable import ClaudeUsage

// Transcript line fixtures shared by the transcript tests
enum Lines {
    static let user = #"{"type":"user","userType":"external","message":{"content":"hi"}}"#
    static let sidechainUser = #"{"type":"user","userType":"external","isSidechain":true}"#
    static let toolResult = #"{"type":"user","userType":"external","message":{"content":[{"type":"tool_result"}]}}"#
    static let assistantTwoTools = #"{"type":"assistant","message":{"content":[{"type":"tool_use"},{"type":"tool_use"}]}}"#

    /// An assistant line carrying usage, as Claude Code writes one per content block
    static func assistant(id: String, model: String = "claude-opus-5-5", timestamp: String = "2026-10-27T10:00:00.000Z",
                          input: Int = 10, output: Int = 20, cacheRead: Int = 900, cacheCreate: Int = 90) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","message":{"id":"\#(id)","model":"\#(model)","content":[{"type":"text"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreate)}}}"#
    }
}

class TranscriptTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ text: String, to name: String = "t.jsonl") throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    func append(_ text: String, to path: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

final class TranscriptCounterTests: TranscriptTestCase {
    private struct Msgs: Equatable {
        let messages: Int, userMessages: Int, toolCalls: Int
    }

    private func msgs(_ c: TranscriptCounter.Counts?) -> Msgs? {
        c.map { Msgs(messages: $0.messages, userMessages: $0.userMessages, toolCalls: $0.toolCalls) }
    }

    func testCountsUserAssistantAndTools() throws {
        let path = try write([Lines.user, Lines.sidechainUser, Lines.toolResult, Lines.assistantTwoTools].joined(separator: "\n") + "\n")
        XCTAssertEqual(msgs(TranscriptCounter().counts(atPath: path)), Msgs(messages: 3, userMessages: 1, toolCalls: 2))
    }

    func testEmptyFile() throws {
        let path = try write("")
        let counts = try XCTUnwrap(TranscriptCounter().counts(atPath: path))
        XCTAssertEqual(counts, TranscriptCounter.Counts())
        XCTAssertNil(counts.tokens.cacheHitRate)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(TranscriptCounter().counts(atPath: dir.appendingPathComponent("nope.jsonl").path))
    }

    func testBytesTrackFileSize() throws {
        let text = Lines.user + "\n" + Lines.assistantTwoTools + "\n"
        let path = try write(text)
        XCTAssertEqual(TranscriptCounter().counts(atPath: path)?.bytes, UInt64(text.utf8.count))
    }

    func testLinesSplitAcrossTinyChunksMatchSingleRead() throws {
        let text = [Lines.user, Lines.assistantTwoTools, "", Lines.user, Lines.toolResult,
                    Lines.assistant(id: "a"), Lines.assistant(id: "a")].joined(separator: "\n") + "\n"
        let path = try write(text)
        let whole = TranscriptCounter().counts(atPath: path)
        for chunk in [1, 3, 7, 64] {
            XCTAssertEqual(TranscriptCounter(chunkSize: chunk).counts(atPath: path), whole, "chunk \(chunk)")
        }
        XCTAssertEqual(msgs(whole), Msgs(messages: 5, userMessages: 2, toolCalls: 2))
    }

    func testIncrementalAppendOnlyAddsNewLines() throws {
        let counter = TranscriptCounter(chunkSize: 5)
        let path = try write(Lines.user + "\n")
        XCTAssertEqual(msgs(counter.counts(atPath: path)), Msgs(messages: 1, userMessages: 1, toolCalls: 0))
        // Unchanged file must not be double counted
        XCTAssertEqual(msgs(counter.counts(atPath: path)), Msgs(messages: 1, userMessages: 1, toolCalls: 0))
        try append(Lines.assistantTwoTools + "\n", to: path)
        XCTAssertEqual(msgs(counter.counts(atPath: path)), Msgs(messages: 2, userMessages: 1, toolCalls: 2))
    }

    func testTrailingLineWithoutNewlineIsCountedOnce() throws {
        let counter = TranscriptCounter(chunkSize: 4)
        // Half of a line written, then the rest
        let line = Lines.assistantTwoTools
        let half = line.index(line.startIndex, offsetBy: 5)
        let path = try write(Lines.user + "\n" + line[..<half])
        XCTAssertEqual(counter.counts(atPath: path)?.messages, 1)
        try append(String(line[half...]), to: path)
        XCTAssertEqual(msgs(counter.counts(atPath: path)), Msgs(messages: 2, userMessages: 1, toolCalls: 2))
        try append("\n", to: path)
        XCTAssertEqual(msgs(counter.counts(atPath: path)), Msgs(messages: 2, userMessages: 1, toolCalls: 2))
    }

    func testTruncatedFileIsRescanned() throws {
        let counter = TranscriptCounter()
        let path = try write([Lines.user, Lines.user, Lines.user].joined(separator: "\n") + "\n")
        XCTAssertEqual(counter.counts(atPath: path)?.messages, 3)
        _ = try write(Lines.assistantTwoTools + "\n")
        XCTAssertEqual(msgs(counter.counts(atPath: path)), Msgs(messages: 1, userMessages: 0, toolCalls: 2))
    }

    func testRetainOnlyDropsState() throws {
        let counter = TranscriptCounter()
        let path = try write(Lines.user + "\n")
        _ = counter.counts(atPath: path)
        counter.retainOnly(paths: [])
        // Fresh scan after the state is dropped still gives the right totals
        XCTAssertEqual(msgs(counter.counts(atPath: path)), Msgs(messages: 1, userMessages: 1, toolCalls: 0))
    }

    func testRepeatedUsageForOneMessageCountedOnce() throws {
        // Three content-block lines for message a, then one for b
        let text = [Lines.assistant(id: "a"), Lines.assistant(id: "a"), Lines.assistant(id: "a"),
                    Lines.assistant(id: "b")].joined(separator: "\n") + "\n"
        let path = try write(text)
        let tokens = try XCTUnwrap(TranscriptCounter().counts(atPath: path)).tokens
        XCTAssertEqual(tokens, DayTokens(input: 20, output: 40, cacheRead: 1800, cacheCreate: 180))
        XCTAssertEqual(try XCTUnwrap(tokens.cacheHitRate), 0.9, accuracy: 0.0001)
    }

    func testDedupeHoldsAcrossIncrementalScans() throws {
        // The repeat of message a arrives in a later scan
        let counter = TranscriptCounter()
        let path = try write(Lines.assistant(id: "a") + "\n")
        XCTAssertEqual(counter.counts(atPath: path)?.tokens.input, 10)
        try append(Lines.assistant(id: "a") + "\n" + Lines.assistant(id: "b") + "\n", to: path)
        XCTAssertEqual(counter.counts(atPath: path)?.tokens.input, 20)
    }
}
