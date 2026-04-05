import Foundation

// MARK: - Parsed message types for UI

enum MessageRole {
    case user
    case assistant
    case system
}

struct ConversationMessage: Identifiable {
    let id: String
    let role: MessageRole
    let timestamp: Date
    let textContent: String
    let thinkingContent: String?
    let toolUses: [ToolUseInfo]
    let toolResult: ToolResultInfo?
    let model: String?
    let tokenUsage: TokenUsageInfo?
    let isToolResult: Bool
}

struct ToolUseInfo: Identifiable {
    let id: String
    let name: String
    let input: String
}

struct ToolResultInfo {
    let toolUseId: String
    let content: String
    let isError: Bool
}

struct TokenUsageInfo {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
}

// MARK: - Raw JSONL structures

private struct RawMessage: Codable {
    let type: String?
    let uuid: String?
    let parentUuid: String?
    let timestamp: String?
    let message: MessageContent?
    let isSidechain: Bool?
    let sessionId: String?
    let toolUseResult: String?
    let subtype: String?

    struct MessageContent: Codable {
        let role: String?
        let model: String?
        let content: ContentValue?
        let usage: UsageInfo?

        enum ContentValue: Codable {
            case text(String)
            case blocks([ContentBlock])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                } else if let blocks = try? container.decode([ContentBlock].self) {
                    self = .blocks(blocks)
                } else {
                    self = .text("")
                }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let s): try container.encode(s)
                case .blocks(let b): try container.encode(b)
                }
            }
        }

        struct ContentBlock: Codable {
            let type: String?
            let text: String?
            let thinking: String?
            let id: String?
            let name: String?
            let input: AnyCodable?
            let content: ToolResultContent?
            let toolUseId: String?
            let isError: Bool?

            enum CodingKeys: String, CodingKey {
                case type, text, thinking, id, name, input, content
                case toolUseId = "tool_use_id"
                case isError = "is_error"
            }

            enum ToolResultContent: Codable {
                case text(String)
                case blocks([ContentBlock])

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let text = try? container.decode(String.self) {
                        self = .text(text)
                    } else if let blocks = try? container.decode([ContentBlock].self) {
                        self = .blocks(blocks)
                    } else {
                        self = .text("")
                    }
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    switch self {
                    case .text(let s): try container.encode(s)
                    case .blocks(let b): try container.encode(b)
                    }
                }

                var asString: String {
                    switch self {
                    case .text(let s): return s
                    case .blocks(let blocks): return blocks.compactMap { $0.text }.joined(separator: "\n")
                    }
                }
            }
        }

        struct UsageInfo: Codable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
            }
        }
    }
}

// Helper for arbitrary JSON
struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let s = value as? String { try container.encode(s) }
        else if let n = value as? Double { try container.encode(n) }
        else if let b = value as? Bool { try container.encode(b) }
        else { try container.encode("") }
    }

    var prettyString: String {
        if let dict = value as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }
        return "\(value)"
    }
}

// MARK: - Loader

final class ConversationLoader {
    static func load(from path: String) -> [ConversationMessage] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let decoder = JSONDecoder()
        var messages: [ConversationMessage] = []

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let raw = try? decoder.decode(RawMessage.self, from: lineData) else { continue }

            // Skip non-message types
            guard let type = raw.type, (type == "user" || type == "assistant") else { continue }
            guard let uuid = raw.uuid else { continue }

            let timestamp = raw.timestamp.flatMap { isoFormatter.date(from: $0) } ?? Date.distantPast
            let role: MessageRole = type == "assistant" ? .assistant : .user
            let model = raw.message?.model

            // Parse content
            var textContent = ""
            var thinkingContent: String?
            var toolUses: [ToolUseInfo] = []
            var toolResult: ToolResultInfo?
            var isToolResult = false

            if let content = raw.message?.content {
                switch content {
                case .text(let text):
                    textContent = text
                case .blocks(let blocks):
                    var textParts: [String] = []
                    for block in blocks {
                        switch block.type {
                        case "text":
                            if let t = block.text { textParts.append(t) }
                        case "thinking":
                            if let t = block.thinking, !t.isEmpty { thinkingContent = t }
                        case "tool_use":
                            let inputStr = block.input?.prettyString ?? ""
                            toolUses.append(ToolUseInfo(
                                id: block.id ?? UUID().uuidString,
                                name: block.name ?? "Unknown",
                                input: inputStr
                            ))
                        case "tool_result":
                            isToolResult = true
                            let resultContent = block.content?.asString ?? block.text ?? raw.toolUseResult ?? ""
                            toolResult = ToolResultInfo(
                                toolUseId: block.toolUseId ?? "",
                                content: resultContent,
                                isError: block.isError ?? false
                            )
                        default:
                            break
                        }
                    }
                    textContent = textParts.joined(separator: "\n")
                }
            }

            // Parse token usage
            var tokenUsage: TokenUsageInfo?
            if let usage = raw.message?.usage {
                tokenUsage = TokenUsageInfo(
                    inputTokens: usage.inputTokens ?? 0,
                    outputTokens: usage.outputTokens ?? 0,
                    cacheReadTokens: usage.cacheReadInputTokens ?? 0,
                    cacheCreationTokens: usage.cacheCreationInputTokens ?? 0
                )
            }

            // Skip empty tool result messages that are just plumbing
            if isToolResult && textContent.isEmpty && toolResult == nil && raw.toolUseResult != nil {
                toolResult = ToolResultInfo(
                    toolUseId: "",
                    content: raw.toolUseResult ?? "",
                    isError: false
                )
            }

            // Skip sidechain messages (subagent internals)
            if raw.isSidechain == true { continue }

            // Skip messages with no visible content
            if textContent.isEmpty && toolUses.isEmpty && toolResult == nil && thinkingContent == nil { continue }

            messages.append(ConversationMessage(
                id: uuid,
                role: role,
                timestamp: timestamp,
                textContent: textContent,
                thinkingContent: thinkingContent,
                toolUses: toolUses,
                toolResult: toolResult,
                model: model,
                tokenUsage: tokenUsage,
                isToolResult: isToolResult
            ))
        }

        return messages
    }
}
