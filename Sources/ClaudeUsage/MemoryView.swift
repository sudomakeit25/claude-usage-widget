import SwiftUI
import AppKit

struct MemoryFile: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let content: String
    let size: Int
    let frontmatter: MemoryFrontmatter?
}

struct MemoryFrontmatter {
    let name: String?
    let description: String?
    let type: String?
}

struct ProjectMemory: Identifiable {
    var id: String { projectPath }
    let projectPath: String
    let projectName: String
    let files: [MemoryFile]
    var totalSize: Int { files.reduce(0) { $0 + $1.size } }
}

// MARK: - Memory Panel (shown in session detail)

struct MemoryPanel: View {
    let projectPath: String
    @State private var memory: ProjectMemory?
    @State private var selectedFile: MemoryFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "brain.filled.head.profile")
                    .foregroundStyle(.purple)
                Text("Project Memory")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let memory {
                    Text("\(memory.files.count) files")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(formatBytes(memory.totalSize))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let memory, !memory.files.isEmpty {
                HStack(spacing: 0) {
                    // File list
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(memory.files) { file in
                                memoryFileRow(file)
                            }
                        }
                    }
                    .frame(width: 200)

                    Divider()

                    // File content
                    if let file = selectedFile {
                        VStack(alignment: .leading, spacing: 0) {
                            // File header
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.caption.weight(.semibold))
                                    if let fm = file.frontmatter {
                                        HStack(spacing: 6) {
                                            if let type = fm.type {
                                                Text(type)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1)
                                                    .background(Capsule().fill(typeColor(type).opacity(0.15)))
                                                    .foregroundStyle(typeColor(type))
                                            }
                                            if let desc = fm.description {
                                                Text(desc)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                }
                                Spacer()
                                Text(formatBytes(file.size))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(file.content, forType: .string)
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(8)

                            Divider()

                            ScrollView {
                                Text(file.content)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        VStack {
                            Spacer()
                            Text("Select a memory file")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                VStack(spacing: 4) {
                    Text("No memory files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.1)))
        .onAppear { loadMemory() }
        .onChange(of: projectPath) { _, _ in loadMemory() }
    }

    private func memoryFileRow(_ file: MemoryFile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: typeIcon(file.frontmatter?.type))
                .font(.caption2)
                .foregroundStyle(typeColor(file.frontmatter?.type ?? ""))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.caption)
                    .lineLimit(1)
                if let desc = file.frontmatter?.description {
                    Text(desc)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(selectedFile?.path == file.path ? Color.gray.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedFile = file }
    }

    private func loadMemory() {
        let fm = FileManager.default
        let encoded = projectPath
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let home = fm.homeDirectoryForCurrentUser.path
        let memoryDir = "\(home)/.claude/projects/\(encoded)/memory"

        guard let files = try? fm.contentsOfDirectory(atPath: memoryDir) else {
            memory = ProjectMemory(projectPath: projectPath, projectName: "", files: [])
            return
        }

        var memFiles: [MemoryFile] = []
        for file in files where file.hasSuffix(".md") {
            let path = "\(memoryDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let content = String(data: data, encoding: .utf8) else { continue }

            let frontmatter = parseFrontmatter(content)

            memFiles.append(MemoryFile(
                path: path,
                name: file,
                content: content,
                size: data.count,
                frontmatter: frontmatter
            ))
        }

        memFiles.sort { $0.name < $1.name }
        memory = ProjectMemory(projectPath: projectPath, projectName: "", files: memFiles)
        selectedFile = memFiles.first { $0.name == "MEMORY.md" } ?? memFiles.first
    }

    private func parseFrontmatter(_ content: String) -> MemoryFrontmatter? {
        guard content.hasPrefix("---") else { return nil }
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3 else { return nil }
        let yaml = parts[1]

        var name: String?
        var description: String?
        var type: String?

        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("description:") {
                description = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("type:") {
                type = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }

        return MemoryFrontmatter(name: name, description: description, type: type)
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "user": return .blue
        case "feedback": return .orange
        case "project": return .green
        case "reference": return .purple
        default: return .gray
        }
    }

    private func typeIcon(_ type: String?) -> String {
        switch type {
        case "user": return "person"
        case "feedback": return "bubble.left"
        case "project": return "folder"
        case "reference": return "link"
        default: return "doc.text"
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
}

// MARK: - Context Window Detail

struct ContextWindowBar: View {
    let contextWindow: ContextWindow
    let model: ModelInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "memorychip")
                    .foregroundStyle(.blue)
                Text("Context Window")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(contextWindow.usedPercentage)% used")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(usageColor)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 10)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(usageColor.gradient)
                        .frame(width: max(0, geo.size.width * CGFloat(contextWindow.usedPercentage) / 100), height: 10)
                }
            }
            .frame(height: 10)

            HStack(spacing: 16) {
                if let input = contextWindow.totalInputTokens {
                    Label(formatTokens(input) + " in", systemImage: "arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let output = contextWindow.totalOutputTokens {
                    Label(formatTokens(output) + " out", systemImage: "arrow.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let size = contextWindow.contextWindowSize {
                    Spacer()
                    Text("\(formatTokens(size)) window")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.1)))
    }

    private var usageColor: Color {
        let pct = contextWindow.usedPercentage
        if pct >= 80 { return .red }
        if pct >= 50 { return .orange }
        return .blue
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}
