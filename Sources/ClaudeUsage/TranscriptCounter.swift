import Foundation

// Counts messages and tokens in session transcripts incrementally. Each file
// is read in chunks and only the bytes appended since the previous scan are
// parsed, so a large live transcript costs almost nothing per refresh.
final class TranscriptCounter {
    struct Counts: Equatable {
        var messages = 0
        var userMessages = 0
        var toolCalls = 0
        var tokens = DayTokens()
        var bytes: UInt64 = 0
    }

    private struct FileState {
        var offset: UInt64 = 0
        var counts = Counts()
        var partialLine = Data()
        var lastMessageId: String?
    }

    private var states: [String: FileState] = [:]
    private let chunkSize: Int

    init(chunkSize: Int = 1 << 20) {
        self.chunkSize = chunkSize
    }

    func counts(atPath path: String) -> Counts? {
        guard let size = JSONLReader.fileSize(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            states[path] = nil
            return nil
        }
        defer { try? handle.close() }

        var state = states[path] ?? FileState()
        // File shrank: it was truncated or replaced, so start over
        if size < state.offset { state = FileState() }

        if size > state.offset {
            do {
                try handle.seek(toOffset: state.offset)
                var partial = state.partialLine
                state.offset += try JSONLReader.readLines(from: handle, chunkSize: chunkSize, partial: &partial) { line in
                    Self.tally(line, into: &state.counts, lastMessageId: &state.lastMessageId)
                }
                state.partialLine = partial
            } catch {
                // Keep what was parsed; the next scan resumes from state.offset
            }
        }
        state.counts.bytes = state.offset
        states[path] = state

        // A final line without a trailing newline is counted but not committed,
        // since more of it may still be written
        var result = state.counts
        if !state.partialLine.isEmpty {
            var lastId = state.lastMessageId
            Self.tally(state.partialLine, into: &result, lastMessageId: &lastId)
        }
        return result
    }

    // Drop cached state for transcripts that are no longer of interest
    func retainOnly(paths: Set<String>) {
        states = states.filter { paths.contains($0.key) }
    }

    private static func tally(_ bytes: Data, into counts: inout Counts, lastMessageId: inout String?) {
        guard !bytes.isEmpty else { return }
        let line = String(decoding: bytes, as: UTF8.self)
        if line.contains("\"type\":\"user\"") && !line.contains("\"tool_result\"") {
            // User message (not a tool result)
            if line.contains("\"userType\":\"external\"") && !line.contains("\"isSidechain\":true") {
                counts.userMessages += 1
            }
            counts.messages += 1
        } else if line.contains("\"type\":\"assistant\"") {
            counts.messages += 1
            counts.toolCalls += line.components(separatedBy: "\"type\":\"tool_use\"").count - 1
            // One API response is split across consecutive lines (one per
            // content block), each repeating the same usage; count it once
            if let usage = TranscriptUsageLine(bytes) {
                if usage.messageId == nil || usage.messageId != lastMessageId {
                    counts.tokens += usage.tokens
                }
                lastMessageId = usage.messageId
            }
        }
    }
}
