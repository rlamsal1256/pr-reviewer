#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.pr-reviewer.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Check prerequisites
for cmd in gh claude jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is not installed."
        exit 1
    fi
done

# Create config from example if missing
if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
    cp "$SCRIPT_DIR/config.example.sh" "$SCRIPT_DIR/config.sh"
    echo "Created config.sh from example. Edit it with your repos before continuing."
    echo "  $SCRIPT_DIR/config.sh"
    exit 0
fi

# Generate launchd plist with correct paths
cat > "$PLIST_PATH" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pr-reviewer</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-l</string>
        <string>${SCRIPT_DIR}/review.sh</string>
    </array>

    <key>StartInterval</key>
    <integer>900</integer>

    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/launchd_stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/launchd_stderr.log</string>

    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLISTEOF

echo "Generated $PLIST_PATH"

# Unload old job if running
launchctl unload "$PLIST_PATH" 2>/dev/null || true

# Load the job
launchctl load "$PLIST_PATH"
echo "Loaded launchd job (polling every 15 minutes)"

# Symlink the summary command
LINK_DIR="/opt/homebrew/bin"
if [[ ! -d "$LINK_DIR" ]]; then
    LINK_DIR="/usr/local/bin"
fi
ln -sf "$SCRIPT_DIR/pr-reviews" "$LINK_DIR/pr-reviews"
echo "Linked pr-reviews to $LINK_DIR/pr-reviews"

echo ""
echo "Done! Run 'pr-reviews status' to verify."
