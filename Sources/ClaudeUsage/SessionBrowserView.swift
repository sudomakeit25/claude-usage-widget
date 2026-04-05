import SwiftUI
import AppKit

struct SessionBrowserView: View {
    @StateObject private var sessionService = SessionListService()
    @State private var selectedSession: SessionInfo?
    @State private var messages: [ConversationMessage] = []
    @State private var searchText = ""
    @State private var isLoadingConversation = false
    @State private var isSearching = false
    @State private var activeFilter: SessionFilter = .all
    @State private var selectedProject: String?
    @State private var searchResults: [SessionInfo]?
    @State private var showDeleteConfirm = false
    @State private var sessionToDelete: SessionInfo?
    @State private var showCommandPalette = false
    @State private var showRenameSheet = false
    @State private var renameText = ""
    @State private var sessionToRename: SessionInfo?
    @State private var showCharts = false
    @State private var showMemory = false

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
            } detail: {
                detail
            }
            .frame(minWidth: 900, minHeight: 600)
            .onAppear { sessionService.loadAll() }
            .alert("Delete Session?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let session = sessionToDelete {
                        sessionService.deleteSession(session)
                        if selectedSession?.sessionId == session.sessionId {
                            selectedSession = nil
                            messages = []
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete the session metadata and transcript. This cannot be undone.")
            }
            .sheet(isPresented: $showRenameSheet) {
                renameSheet
            }

            // Command palette overlay
            if showCommandPalette {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showCommandPalette = false }

                VStack {
                    CommandPalette(
                        isPresented: $showCommandPalette,
                        sessions: sessionService.allSessions,
                        onSelect: { session in
                            selectedSession = session
                            loadConversation(session)
                        }
                    )
                    .padding(.top, 80)
                    Spacer()
                }
            }
        }
        .onKeyPress(keys: [KeyEquivalent("k")]) { press in
            if press.modifiers.contains(.command) {
                showCommandPalette.toggle()
                return .handled
            }
            return .ignored
        }
    }

    // Rename sheet
    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Session")
                .font(.headline)
            TextField("Session title", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Button("Clear") {
                    if let session = sessionToRename {
                        sessionService.renameSession(session.sessionId, title: nil)
                    }
                    showRenameSheet = false
                }
                Spacer()
                Button("Cancel") { showRenameSheet = false }
                Button("Save") {
                    if let session = sessionToRename {
                        sessionService.renameSession(session.sessionId, title: renameText)
                    }
                    showRenameSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("Search sessions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .onSubmit { performSearch() }
                if !searchText.isEmpty {
                    Button(action: { searchText = ""; searchResults = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // Filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SessionFilter.allCases, id: \.self) { filter in
                        FilterChip(label: filter.rawValue, isActive: activeFilter == filter) {
                            activeFilter = filter
                            searchResults = nil
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 6)

            // Project filter
            if !sessionService.projectNames.isEmpty {
                Menu {
                    Button("All Projects") { selectedProject = nil }
                    Divider()
                    ForEach(sessionService.projectNames, id: \.self) { name in
                        Button(name) { selectedProject = name }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.caption2)
                        Text(selectedProject ?? "All Projects")
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.gray.opacity(0.1)))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            Divider()

            // Session count
            HStack {
                Text("\(displayedSessions.count) sessions")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            // Session list
            if isSearching {
                Spacer()
                ProgressView("Searching...")
                    .font(.caption)
                Spacer()
            } else {
                List(selection: $selectedSession) {
                    ForEach(displayedSessions) { session in
                        SidebarSessionRow(
                            session: session,
                            isSelected: selectedSession?.sessionId == session.sessionId,
                            onResume: { resumeSession(session) }
                        )
                        .tag(session)
                        .contextMenu { sessionContextMenu(session) }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selectedSession) { _, newSession in
                    if let session = newSession {
                        showCharts = false
                        loadConversation(session)
                    }
                }
            }

            Spacer(minLength: 0)

            // Bottom bar
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.title3)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Claude Code")
                        .font(.caption.weight(.medium))
                    Text("Max plan")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { sessionService.loadAll() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func sessionContextMenu(_ session: SessionInfo) -> some View {
        Button(action: { resumeSession(session) }) {
            Label("Resume Session", systemImage: "play")
        }

        Divider()

        Button(action: { sessionService.togglePin(session.sessionId) }) {
            Label(
                session.isPinned ? "Unpin" : "Pin to Top",
                systemImage: session.isPinned ? "pin.slash" : "pin"
            )
        }

        Button(action: { sessionService.toggleBookmark(session.sessionId) }) {
            Label(
                session.isBookmarked ? "Remove Bookmark" : "Bookmark",
                systemImage: session.isBookmarked ? "bookmark.slash" : "bookmark"
            )
        }

        Button(action: {
            sessionToRename = session
            renameText = session.customTitle ?? session.firstPrompt
            showRenameSheet = true
        }) {
            Label("Rename", systemImage: "pencil")
        }

        Divider()

        Button(action: { exportSession(session) }) {
            Label("Export as Markdown", systemImage: "square.and.arrow.up")
        }

        if let path = session.transcriptPath {
            Button(action: { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }) {
                Label("Show in Finder", systemImage: "folder")
            }
        }

        Divider()

        Button(role: .destructive, action: {
            sessionToDelete = session
            showDeleteConfirm = true
        }) {
            Label("Delete Session", systemImage: "trash")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if showCharts {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: { showCharts = false }) {
                        Label("Back to Sessions", systemImage: "chevron.left")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()

                ScrollView {
                    UsageChartsView(sessions: sessionService.allSessions, onSelectSession: { session in
                        showCharts = false
                        selectedSession = session
                        loadConversation(session)
                    })
                }
            }
        } else if let session = selectedSession {
            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Button(action: {
                        selectedSession = nil
                        messages = []
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.caption2)
                            Text("Home")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)

                    if session.isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(shortProjectName(session.projectPath))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: { showMemory.toggle() }) {
                        Label("Memory", systemImage: "brain.filled.head.profile")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("View project memory")
                    .foregroundStyle(showMemory ? .purple : .secondary)

                    Button(action: { exportSession(session) }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Export as Markdown")

                    Button(action: { resumeSession(session) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                            Text("Resume")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                if isLoadingConversation {
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                    Spacer()
                } else if messages.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("No transcript available")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    if showMemory {
                        HSplitView {
                            conversationView
                            VStack(spacing: 8) {
                                // Context window from live session data
                                if let liveSession = liveSessionData(for: session),
                                   let ctx = liveSession.contextWindow {
                                    ContextWindowBar(contextWindow: ctx, model: liveSession.model)
                                }
                                MemoryPanel(projectPath: session.projectPath)
                            }
                            .frame(minWidth: 300, idealWidth: 350)
                            .padding(8)
                        }
                    } else {
                        conversationView
                    }
                }

                Divider()
                sessionInfoBar(session)
            }
        } else {
            welcomeView
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Claude Code Sessions")
                .font(.largeTitle.weight(.bold))

            Text("\(sessionService.allSessions.count) sessions across \(sessionService.projects.count) projects")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: { showCharts = true }) {
                Label("View Usage Charts", systemImage: "chart.bar")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)

            Spacer()

            if !sessionService.allSessions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recent sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)

                    ForEach(sessionService.allSessions.prefix(5)) { session in
                        Button(action: {
                            selectedSession = session
                            loadConversation(session)
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "bubble.left")
                                    .font(.subheadline)
                                    .foregroundStyle(.purple)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(Color.purple.opacity(0.1)))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.firstPrompt.isEmpty ? "Session" : String(session.firstPrompt.prefix(60)))
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(relativeDate(session.startTime))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if session.id != sessionService.allSessions.prefix(5).last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .frame(maxWidth: 500)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.1)))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var conversationView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                        if message.id != messages.last?.id {
                            Divider().padding(.leading, 50)
                        }
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func sessionInfoBar(_ session: SessionInfo) -> some View {
        HStack(spacing: 16) {
            Label("\(session.totalMessages) messages", systemImage: "message")
            Label("\(session.durationMinutes) min", systemImage: "clock")
            Label(formatTokens(session.inputTokens + session.outputTokens) + " tokens", systemImage: "number")
            if session.linesAdded > 0 || session.linesRemoved > 0 {
                HStack(spacing: 4) {
                    Text("+\(session.linesAdded)").foregroundStyle(.green)
                    Text("-\(session.linesRemoved)").foregroundStyle(.red)
                }
                .font(.system(.caption, design: .monospaced))
            }
            Spacer()
            Text(formatDate(session.startTime))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Displayed sessions

    private var displayedSessions: [SessionInfo] {
        let base = searchResults ?? sessionService.allSessions
        let filtered = sessionService.filtered(sessions: base, by: activeFilter, project: selectedProject)
        // Pinned sessions first
        let pinned = filtered.filter { $0.isPinned }
        let unpinned = filtered.filter { !$0.isPinned }
        return pinned + unpinned
    }

    // MARK: - Search

    private func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = nil
            return
        }
        isSearching = true
        let query = searchText
        DispatchQueue.global(qos: .userInitiated).async {
            let results = sessionService.searchContent(query: query)
            DispatchQueue.main.async {
                searchResults = results
                isSearching = false
            }
        }
    }

    // MARK: - Resume

    private func resumeSession(_ session: SessionInfo) {
        let dir = session.projectPath
        let sessionId = session.sessionId
        // Detect iTerm2
        let hasITerm = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil

        let script: String
        if hasITerm {
            script = """
                tell application "iTerm"
                    activate
                    set newWindow to (create window with default profile)
                    tell current session of newWindow
                        write text "cd \\"\(dir)\\" && claude --resume \\"\(sessionId)\\""
                    end tell
                end tell
                """
        } else {
            script = """
                tell application "Terminal"
                    activate
                    do script "cd \\"\(dir)\\" && claude --resume \\"\(sessionId)\\""
                end tell
                """
        }

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // MARK: - Export

    private func exportSession(_ session: SessionInfo) {
        let md = SessionListService.exportToMarkdown(session, messages: messages)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.firstPrompt.prefix(30).replacingOccurrences(of: "/", with: "-")).md"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? md.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Loading

    private func loadConversation(_ session: SessionInfo) {
        guard let path = session.transcriptPath else {
            messages = []
            return
        }
        isLoadingConversation = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = ConversationLoader.load(from: path)
            DispatchQueue.main.async {
                messages = loaded
                isLoadingConversation = false
            }
        }
    }

    // MARK: - Live Session Data

    private func liveSessionData(for session: SessionInfo) -> StatusLineData? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let statusDir = "\(home)/.claude/session-status"
        let path = "\(statusDir)/\(session.sessionId).json"
        guard let data = fm.contents(atPath: path),
              let live = try? JSONDecoder().decode(StatusLineData.self, from: data) else { return nil }
        return live
    }

    // MARK: - Helpers

    private func shortProjectName(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count >= 2 {
            return String(components.suffix(2).joined(separator: "/"))
        }
        return String(components.last ?? "")
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(isActive ? Color.purple.opacity(0.15) : Color.gray.opacity(0.08)))
                .foregroundStyle(isActive ? .purple : .secondary)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Sidebar Session Row

struct SidebarSessionRow: View {
    let session: SessionInfo
    let isSelected: Bool
    var onResume: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.orange)
                }
                if session.isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.blue)
                }
                Text(String(session.displayTitle.prefix(40)))
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                if isHovered {
                    Button(action: onResume) {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .help("Resume in Terminal")
                } else {
                    Text(String(format: "$%.0f", session.estimatedCost))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 6) {
                Text(shortPath(session.projectPath))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Text(relativeDate(session.startTime))
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .opacity(isHovered ? 1 : 0)
            .frame(height: 14)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.gray.opacity(0.15) : isHovered ? Color.gray.opacity(0.08) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(session.projectPath)
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
