cask "claude-usage-widget" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/sudomakeit25/claude-usage-widget/releases/download/v#{version}/ClaudeUsage-#{version}.zip"
  name "Claude Usage"
  desc "Menu bar app and session browser for Claude Code usage monitoring"
  homepage "https://github.com/sudomakeit25/claude-usage-widget"

  depends_on macos: ">= :sonoma"

  app "ClaudeUsage.app"

  zap trash: [
    "~/Library/Preferences/com.local.claude-usage.plist",
    "~/Library/Application Support/ClaudeUsage",
  ]
end
