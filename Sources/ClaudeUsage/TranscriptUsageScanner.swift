import Foundation

// Per-day and per-model token usage for transcripts, cached per file. A file
// that hasn't changed since the last scan isn't read again, and a file that
// grew is only read from where the previous scan stopped.
final class TranscriptUsageScanner {
    struct Usage: Equatable {
        var perDay: [String: DayTokens] = [:]
        var perModel: [String: DayTokens] = [:]
        var total = DayTokens()
    }

    private struct FileState {
        var offset: UInt64 = 0
        var partialLine = Data()
        var lastMessageId: String?
        var usage = Usage()
    }

    private var states: [String: FileState] = [:]
    private let lock = NSLock()
    private let chunkSize: Int
    private let isoFormatter: ISO8601DateFormatter
    private let dayFormatter: DateFormatter

    init(chunkSize: Int = 1 << 20, timeZone: TimeZone = .current) {
        self.chunkSize = chunkSize
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = timeZone
    }

    func usage(atPath path: String) -> Usage {
        lock.lock()
        defer { lock.unlock() }

        guard let size = JSONLReader.fileSize(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            states[path] = nil
            return Usage()
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
                    add(line, to: &state.usage, lastMessageId: &state.lastMessageId)
                }
                state.partialLine = partial
            } catch {
                // Keep what was parsed; the next scan resumes from state.offset
            }
        }
        states[path] = state

        // A final line without a trailing newline is included but not committed
        var result = state.usage
        if !state.partialLine.isEmpty {
            var lastId = state.lastMessageId
            add(state.partialLine, to: &result, lastMessageId: &lastId)
        }
        return result
    }

    private func add(_ line: Data, to usage: inout Usage, lastMessageId: inout String?) {
        guard let parsed = TranscriptUsageLine(line) else { return }
        // One API response is split across consecutive lines (one per content
        // block), each repeating the same usage; count it once
        defer { lastMessageId = parsed.messageId }
        if let id = parsed.messageId, id == lastMessageId { return }

        let dayKey: String
        if let ts = parsed.timestamp, let date = isoFormatter.date(from: ts) {
            dayKey = dayFormatter.string(from: date)
        } else {
            dayKey = "unknown"
        }
        usage.total += parsed.tokens
        usage.perDay[dayKey, default: DayTokens()] += parsed.tokens
        usage.perModel[parsed.model ?? "unknown", default: DayTokens()] += parsed.tokens
    }
}
