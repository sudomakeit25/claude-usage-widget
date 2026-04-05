#!/bin/bash
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
STATUSLINE_SCRIPT="$CLAUDE_DIR/statusline.sh"

echo "=== Claude Usage Widget Setup ==="
echo ""

# Check if claude is installed
CLAUDE_BIN=""
if command -v claude &>/dev/null; then
    CLAUDE_BIN=$(command -v claude)
elif [ -x "$HOME/.local/bin/claude" ]; then
    CLAUDE_BIN="$HOME/.local/bin/claude"
elif [ -x "/usr/local/bin/claude" ]; then
    CLAUDE_BIN="/usr/local/bin/claude"
elif [ -x "/opt/homebrew/bin/claude" ]; then
    CLAUDE_BIN="/opt/homebrew/bin/claude"
fi

if [ -z "$CLAUDE_BIN" ]; then
    echo "Error: Claude Code CLI not found."
    echo "Install it from: https://claude.ai/code"
    exit 1
fi

echo "Found Claude CLI: $CLAUDE_BIN"

# Check auth
if ! "$CLAUDE_BIN" auth status &>/dev/null; then
    echo "Warning: Claude Code is not authenticated."
    echo "Run: claude auth login"
fi

# Create statusline script
echo "Creating statusline script..."
cat > "$STATUSLINE_SCRIPT" << 'EOF'
#!/bin/bash
input=$(cat)
mkdir -p ~/.claude/session-status
session_id=$(echo "$input" | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null)
echo "$input" > ~/.claude/session-status/${session_id}.json
echo "$input" > ~/.claude/rate-limits.json
EOF
chmod +x "$STATUSLINE_SCRIPT"
echo "  Created: $STATUSLINE_SCRIPT"

# Configure settings.json
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Creating settings.json..."
    cat > "$SETTINGS_FILE" << SETTINGSEOF
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
SETTINGSEOF
    echo "  Created: $SETTINGS_FILE"
else
    # Check if statusLine is already configured
    if grep -q '"statusLine"' "$SETTINGS_FILE" 2>/dev/null; then
        echo "  statusLine already configured in settings.json"
    else
        echo ""
        echo "Your settings.json exists but doesn't have the statusLine config."
        echo "Please add the following to your $SETTINGS_FILE:"
        echo ""
        echo '  "statusLine": {'
        echo '    "type": "command",'
        echo '    "command": "bash ~/.claude/statusline.sh"'
        echo '  }'
        echo ""
        echo "This is required for the widget to receive live rate limit data."
    fi
fi

# Create session-status directory
mkdir -p "$CLAUDE_DIR/session-status"

# Build the app
echo ""
echo "Building ClaudeUsage.app..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"
bash Scripts/build.sh

# Install
echo ""
echo "Installing to ~/Applications..."
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/ClaudeUsage.app"
cp -r build/ClaudeUsage.app "$HOME/Applications/"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "To launch:  open ~/Applications/ClaudeUsage.app"
echo ""
echo "The brain icon will appear in your menu bar."
echo "Click it to see your Claude Code usage limits."
echo "Click 'Sessions' to browse all your past sessions."
echo ""
echo "Tip: Add to Login Items (System Settings > General > Login Items)"
echo "     to start automatically on boot."
echo ""
echo "Note: Start a Claude Code session to populate live data."
echo "      Historical data from past sessions will appear immediately."
