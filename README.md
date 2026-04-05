# Claude Usage Widget

A macOS menu bar app for monitoring Claude Code usage limits, browsing sessions, and analyzing usage patterns.

Built for Claude Code Max/Pro users who want visibility into their rate limits, session history, and token consumption without leaving the desktop.

## Features

### Menu Bar Widget
- **Rate limits** with progress bars and reset countdowns (5-hour and 7-day windows)
- **Active sessions** showing model, project, API-equivalent cost, context window usage, and lines changed
- **Today / This Week** stats: prompts, messages, sessions, tool calls, tokens
- **Model breakdown**: all-time token usage per model
- **Recent sessions** with first prompt preview
- **80% usage alerts** via macOS notifications

### Session Browser (click "Sessions" or press Cmd+Shift+C)
- **Browse all sessions** grouped by project with search
- **Read full conversations** with markdown rendering, code blocks with copy buttons
- **Filter** by date (Today, This Week, This Month), project, or bookmarks
- **Pin** sessions to top of sidebar
- **Rename** sessions with custom titles
- **Bookmark** important sessions
- **Resume** sessions in Terminal or iTerm2 (auto-detected)
- **Export** conversations as Markdown
- **Delete** sessions you no longer need
- **Cmd+K command palette** for quick navigation
- **Project memory viewer** showing auto-memory files with frontmatter parsing
- **Context window** usage bar with token breakdown

### Usage Charts (click "View Usage Charts")
- Daily sessions and daily cost (API equivalent)
- Hourly activity heatmap
- Session duration distribution
- Cost per project
- Sessions per project
- Top tools used
- Lines changed per project
- Tokens per message (efficiency)
- Session length vs messages (scatter plot)
- Cumulative cost over time
- Average session duration trend
- Hover on daily cost to see which sessions caused spikes

## Requirements

- macOS 14+ (Sonoma or later)
- Swift 6.0+ (included with Xcode 16+)
- [Claude Code](https://claude.ai/code) CLI installed and authenticated

## Quick Start

```bash
git clone https://github.com/sudomakeit25/claude-usage-widget.git
cd claude-usage-widget
bash Scripts/setup.sh
```

The setup script will:
1. Detect your Claude Code installation
2. Create the statusline hook for live data
3. Guide you through configuring `settings.json`
4. Build and install the app to `~/Applications/`
5. Provide instructions for auto-start on login

Then launch:
```bash
open ~/Applications/ClaudeUsage.app
```

## Manual Installation

### 1. Configure the statusline hook

Create the script that persists session data:

```bash
cat > ~/.claude/statusline.sh << 'EOF'
#!/bin/bash
input=$(cat)
mkdir -p ~/.claude/session-status
session_id=$(echo "$input" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null)
echo "$input" > ~/.claude/session-status/${session_id}.json
echo "$input" > ~/.claude/rate-limits.json
EOF
chmod +x ~/.claude/statusline.sh
```

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

### 2. Build

```bash
bash Scripts/build.sh
```

### 3. Install

```bash
cp -r build/ClaudeUsage.app ~/Applications/
open ~/Applications/ClaudeUsage.app
```

### 4. Start on login (optional)

System Settings > General > Login Items > + > select ClaudeUsage

## How It Works

The app reads data from several sources in `~/.claude/`:

| Source | Data | Updated |
|--------|------|---------|
| `session-status/*.json` | Live rate limits, cost, context window | Every statusline refresh (~seconds) |
| `rate-limits.json` | Latest session's full statusline data | Every statusline refresh |
| `stats-cache.json` | Historical daily activity, model usage | Periodically by Claude Code |
| `usage-data/session-meta/` | Per-session metadata (tokens, tools, duration) | When sessions end |
| `projects/*/memory/` | Auto-memory files | When Claude writes memory |

The statusline hook writes per-session JSON files so the widget can track multiple concurrent sessions.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+Shift+C | Open session browser (global hotkey) |
| Cmd+K | Command palette (quick jump to session) |

## What the Numbers Mean

| Metric | Description |
|--------|-------------|
| **Current session (5-hour)** | Usage % of your rolling 5-hour rate limit window |
| **All models (7-day)** | Usage % of your rolling 7-day rate limit window |
| **API equiv.** | What the session's token usage would cost at standard API pricing. On Max/Pro plans this is informational, not an actual charge |
| **Prompts** | Number of messages you typed (excludes tool results and subagent messages) |
| **Messages** | Total messages in the conversation (user + assistant + tool results) |
| **ctx %** | How much of the model's context window is used |

## Updating

```bash
cd claude-usage-widget
git pull
bash Scripts/build.sh
pkill -x ClaudeUsage
cp -r build/ClaudeUsage.app ~/Applications/
open ~/Applications/ClaudeUsage.app
```

## Project Structure

```
claude-usage-widget/
  Package.swift                             # Swift Package Manager config
  Sources/ClaudeUsage/
    App.swift                               # Menu bar + window entry point, global hotkey
    Models.swift                            # Data models for all JSON sources
    UsageDataService.swift                  # File reading, parsing, auto-refresh, alerts
    MenuBarView.swift                       # Menu bar popover UI
    SessionBrowserView.swift                # Session browser window with sidebar
    SessionListService.swift                # Session loading, search, bookmarks, pins
    ConversationLoader.swift                # JSONL transcript parser
    MessageView.swift                       # Chat message rendering with markdown
    CommandPalette.swift                    # Cmd+K quick navigation
    UsageCharts.swift                       # 12 usage charts with Swift Charts
    MemoryView.swift                        # Project memory viewer + context window bar
  Scripts/
    setup.sh                                # One-command setup
    build.sh                                # Build + create .app bundle
  Resources/
    AppIcon.icns                            # App icon
```

## Troubleshooting

**Menu bar shows 0% but I've been using Claude Code:**
The statusline hook may not be configured. Run `bash Scripts/setup.sh` or manually add the `statusLine` setting to `~/.claude/settings.json`.

**Rate limits show stale data:**
The widget checks `resets_at` timestamps and shows 0% if the limit has already reset. Start a new Claude Code session to get fresh data.

**No sessions appear in the browser:**
Session metadata is stored in `~/.claude/usage-data/session-meta/`. If this directory is empty, Claude Code may not have written metadata yet. Active sessions appear once the statusline hook fires.

**Resume doesn't start Claude:**
The app tries to find the `claude` binary at `~/.local/bin/claude`, `/usr/local/bin/claude`, and `/opt/homebrew/bin/claude`. If yours is elsewhere, the app falls back to `claude` via PATH in a login shell.

**macOS blocks the app ("unidentified developer"):**
Right-click the app > Open > Open. You only need to do this once.

**App doesn't appear in Cmd+Tab:**
Rebuild the app. Older versions had `LSUIElement` set which hides from the app switcher.

## License

MIT
