import SwiftUI

struct CommandPalette: View {
    @Binding var isPresented: Bool
    let sessions: [SessionInfo]
    let onSelect: (SessionInfo) -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool

    private var filtered: [SessionInfo] {
        if query.isEmpty { return Array(sessions.prefix(15)) }
        let q = query.lowercased()
        return sessions.filter {
            $0.displayTitle.lowercased().contains(q) ||
            $0.projectName.lowercased().contains(q)
        }.prefix(15).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Jump to session...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit { selectCurrent() }

                Text("esc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))
            }
            .padding(16)

            Divider()

            // Results
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, session in
                        HStack(spacing: 10) {
                            Image(systemName: "bubble.left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(String(session.displayTitle.prefix(60)))
                                    .font(.subheadline)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(session.projectName)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Text(relativeDate(session.startTime))
                                        .font(.caption2)
                                        .foregroundStyle(.quaternary)
                                }
                            }

                            Spacer()

                            if session.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(index == selectedIndex ? Color.purple.opacity(0.1) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(session)
                            isPresented = false
                        }
                    }
                }
            }
            .frame(maxHeight: 400)

            if filtered.isEmpty {
                VStack(spacing: 4) {
                    Text("No sessions found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        .frame(width: 500)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20)
        .onAppear {
            isFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onKeyPress(.upArrow) { selectedIndex = max(0, selectedIndex - 1); return .handled }
        .onKeyPress(.downArrow) { selectedIndex = min(filtered.count - 1, selectedIndex + 1); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }

    private func selectCurrent() {
        guard selectedIndex < filtered.count else { return }
        onSelect(filtered[selectedIndex])
        isPresented = false
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
