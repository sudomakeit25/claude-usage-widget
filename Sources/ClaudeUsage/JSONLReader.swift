import Foundation

// Chunked JSONL reading shared by the transcript scanners. Transcripts can be
// hundreds of MB, so files are never loaded whole: memory stays bounded by
// the chunk size plus the longest single line.
enum JSONLReader {
    /// Reads `handle` from its current position to EOF and calls `onLine` for
    /// every complete line. Bytes after the last newline are carried in
    /// `partial` so a later call can finish the line once more is written.
    /// Returns the number of bytes consumed from the file.
    @discardableResult
    static func readLines(from handle: FileHandle, chunkSize: Int, partial: inout Data, onLine: (Data) -> Void) throws -> UInt64 {
        var consumed: UInt64 = 0
        while true {
            let more: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                consumed += UInt64(chunk.count)
                var start = chunk.startIndex
                while let newline = chunk[start...].firstIndex(of: 0x0A) {
                    if partial.isEmpty {
                        onLine(chunk[start..<newline])
                    } else {
                        partial.append(chunk[start..<newline])
                        onLine(partial)
                        partial = Data()
                    }
                    start = chunk.index(after: newline)
                }
                partial.append(chunk[start...])
                return true
            }
            if !more { return consumed }
        }
    }

    static func fileSize(atPath path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.size] as? NSNumber)?.uint64Value
    }
}

// Token usage carried by one assistant transcript line
struct TranscriptUsageLine {
    let messageId: String?
    let model: String?
    let timestamp: String?
    let tokens: DayTokens

    private static let usageMarker = Data("\"usage\"".utf8)

    /// Parses usage from a transcript line, or nil if it has none. Lines
    /// without the marker are skipped before any JSON parsing.
    init?(_ line: Data) {
        guard line.range(of: Self.usageMarker) != nil,
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let msg = json["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return nil }
        messageId = msg["id"] as? String
        model = msg["model"] as? String
        timestamp = json["timestamp"] as? String
        tokens = DayTokens(
            input: (usage["input_tokens"] as? Int) ?? 0,
            output: (usage["output_tokens"] as? Int) ?? 0,
            cacheRead: (usage["cache_read_input_tokens"] as? Int) ?? 0,
            cacheCreate: (usage["cache_creation_input_tokens"] as? Int) ?? 0
        )
    }
}

extension DayTokens {
    static func += (lhs: inout DayTokens, rhs: DayTokens) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheCreate += rhs.cacheCreate
    }

    /// Share of prompt tokens served from cache, or nil with no prompt tokens
    var cacheHitRate: Double? {
        let prompt = input + cacheRead + cacheCreate
        guard prompt > 0 else { return nil }
        return Double(cacheRead) / Double(prompt)
    }
}
