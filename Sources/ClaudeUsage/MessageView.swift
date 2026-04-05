import SwiftUI

struct MessageView: View {
    let message: ConversationMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                headerRow

                // Text content
                if !message.isToolResult && !message.textContent.isEmpty {
                    Text(message.textContent)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                }

                // Thinking
                if let thinking = message.thinkingContent, !thinking.isEmpty {
                    thinkingView(thinking)
                }

                // Tool uses
                ForEach(message.toolUses) { tool in
                    toolUseView(tool)
                }

                // Tool result
                if let result = message.toolResult {
                    toolResultView(result)
                }

                // Token badge for assistant
                if let usage = message.tokenUsage, message.role == .assistant {
                    HStack(spacing: 8) {
                        Text("\(usage.outputTokens) tokens")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    // MARK: - Avatar

    private var avatar: some View {
        Group {
            if message.role == .user {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.blue)
                    )
            } else {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "brain")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                    )
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(message.role == .user ? "You" : "Claude")
                .font(.subheadline.weight(.semibold))
            if let model = message.model {
                Text(shortModel(model))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.gray.opacity(0.1)))
            }
            Spacer()
            Text(formatTime(message.timestamp))
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: - Thinking

    private func thinkingView(_ thinking: String) -> some View {
        DisclosureGroup {
            Text(thinking)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                Text("Thinking")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.05)))
    }

    // MARK: - Tool Use

    private func toolUseView(_ tool: ToolUseInfo) -> some View {
        DisclosureGroup {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(tool.input)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxHeight: 150)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: toolIcon(tool.name))
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(tool.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.1)))
    }

    // MARK: - Tool Result

    private func toolResultView(_ result: ToolResultInfo) -> some View {
        DisclosureGroup {
            ScrollView {
                Text(result.content.prefix(3000).description)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: result.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(result.isError ? .red : .green)
                Text(result.isError ? "Error" : "Result")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(result.isError ? .red : .primary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            result.isError ? Color.red.opacity(0.04) : Color.green.opacity(0.04)
        ))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
            result.isError ? Color.red.opacity(0.1) : Color.green.opacity(0.1)
        ))
    }

    // MARK: - Helpers

    private func shortModel(_ name: String) -> String {
        if name.contains("opus-4-6") { return "Opus 4.6" }
        if name.contains("opus-4-5") { return "Opus 4.5" }
        if name.contains("sonnet-4-6") { return "Sonnet 4.6" }
        if name.contains("sonnet-4-5") { return "Sonnet 4.5" }
        if name.contains("haiku") { return "Haiku" }
        return name
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "Read": return "doc.text"
        case "Write": return "doc.badge.plus"
        case "Edit": return "pencil"
        case "Bash": return "terminal"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "Agent": return "person.2"
        case "WebFetch": return "globe"
        case "WebSearch": return "globe.americas"
        case "TaskCreate": return "checklist"
        case "TaskUpdate": return "checklist.checked"
        default: return "wrench"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
