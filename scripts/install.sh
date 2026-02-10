#!/usr/bin/env bash
set -euo pipefail

# Google Tasks Agent - Installation Script
# Supports macOS (launchd) and Linux (systemd)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$HOME/.google-tasks-agent"
VENV_DIR="$CONFIG_DIR/venv"
LOG_DIR="$CONFIG_DIR/logs"

OS="$(uname -s)"
USERNAME="$(whoami)"

echo "=== Google Tasks Agent Installer ==="
echo ""

# Detect OS
if [ "$OS" = "Darwin" ]; then
    echo "Platform: macOS (launchd)"
elif [ "$OS" = "Linux" ]; then
    echo "Platform: Linux (systemd)"
else
    echo "Error: Unsupported platform: $OS"
    exit 1
fi
echo ""

# Check for Claude Code CLI (required by claude-agent-sdk)
if ! command -v claude &>/dev/null; then
    echo "Warning: 'claude' CLI not found in PATH."
    echo "The Claude Agent SDK requires Claude Code to be installed."
    echo "Install it with: npm install -g @anthropic-ai/claude-code"
    echo ""
fi

# Check for Node.js (required for MCP server)
if ! command -v node &>/dev/null; then
    echo "Error: 'node' not found in PATH. Node.js is required for the MCP server."
    exit 1
fi

# Check MCP server exists
MCP_SERVER_PATH="${GOOGLE_TASKS_AGENT_MCP_SERVER_PATH:-$HOME/Code/google-mcp/dist/index.js}"
if [ ! -f "$MCP_SERVER_PATH" ]; then
    echo "Warning: MCP server not found at $MCP_SERVER_PATH"
    echo "Build it first: cd ~/Code/google-mcp && npm run build"
    echo ""
fi

# Prompt for API key
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "Enter your Anthropic API key (or press Enter to skip):"
    read -r ANTHROPIC_API_KEY
    if [ -z "$ANTHROPIC_API_KEY" ]; then
        echo "Warning: No API key provided. Set ANTHROPIC_API_KEY before running."
    fi
fi

# Prompt for user email
if [ -z "${GOOGLE_TASKS_AGENT_USER_EMAIL:-}" ]; then
    echo "Enter your email address (for name matching in Gemini notes, or press Enter to skip):"
    read -r USER_EMAIL
else
    USER_EMAIL="$GOOGLE_TASKS_AGENT_USER_EMAIL"
fi

echo ""
echo "Creating directories..."
mkdir -p "$CONFIG_DIR"
mkdir -p "$LOG_DIR"

echo "Setting up Python virtual environment..."
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet "$PROJECT_DIR"

echo "Installed google-tasks-agent into $VENV_DIR"

# Verify installation
if "$VENV_DIR/bin/google-tasks-agent" --help &>/dev/null; then
    echo "Installation verified successfully."
else
    echo "Warning: Installation may have issues. Check logs."
fi

echo ""

# Platform-specific scheduling setup
if [ "$OS" = "Darwin" ]; then
    PLIST_NAME="com.${USERNAME}.google-tasks-agent"
    PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
    TEMPLATE="$PROJECT_DIR/templates/com.user.google-tasks-agent.plist.template"

    echo "Setting up launchd agent..."

    # Unload existing agent if present
    if launchctl list "$PLIST_NAME" &>/dev/null 2>&1; then
        echo "Stopping existing agent..."
        launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    fi

    # Generate plist from template
    sed -e "s|{{HOME}}|$HOME|g" \
        -e "s|{{USERNAME}}|$USERNAME|g" \
        -e "s|{{ANTHROPIC_API_KEY}}|${ANTHROPIC_API_KEY:-}|g" \
        -e "s|{{USER_EMAIL}}|${USER_EMAIL:-}|g" \
        "$TEMPLATE" > "$PLIST_PATH"

    # Load the agent
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

    echo "Launchd agent installed at: $PLIST_PATH"
    echo "Agent will run every 5 minutes."
    echo ""
    echo "To check status:  launchctl list | grep google-tasks-agent"
    echo "To stop:          launchctl bootout gui/$(id -u)/$PLIST_NAME"
    echo "To start:         launchctl bootstrap gui/$(id -u) $PLIST_PATH"

elif [ "$OS" = "Linux" ]; then
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"

    SERVICE_TEMPLATE="$PROJECT_DIR/templates/google-tasks-agent.service.template"
    TIMER_TEMPLATE="$PROJECT_DIR/templates/google-tasks-agent.timer.template"

    echo "Setting up systemd timer..."

    # Stop existing timer if present
    systemctl --user stop google-tasks-agent.timer 2>/dev/null || true
    systemctl --user disable google-tasks-agent.timer 2>/dev/null || true

    # Generate service file from template
    sed -e "s|{{HOME}}|$HOME|g" \
        -e "s|{{ANTHROPIC_API_KEY}}|${ANTHROPIC_API_KEY:-}|g" \
        -e "s|{{USER_EMAIL}}|${USER_EMAIL:-}|g" \
        "$SERVICE_TEMPLATE" > "$SYSTEMD_DIR/google-tasks-agent.service"

    # Copy timer file
    cp "$TIMER_TEMPLATE" "$SYSTEMD_DIR/google-tasks-agent.timer"

    # Enable and start timer
    systemctl --user daemon-reload
    systemctl --user enable --now google-tasks-agent.timer

    echo "Systemd timer installed and started."
    echo ""
    echo "To check status:  systemctl --user status google-tasks-agent.timer"
    echo "To view logs:     journalctl --user -u google-tasks-agent"
    echo "To stop:          systemctl --user stop google-tasks-agent.timer"
    echo "To disable:       systemctl --user disable google-tasks-agent.timer"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Configuration directory: $CONFIG_DIR"
echo "Logs directory:          $LOG_DIR"
echo "Action items log:        $CONFIG_DIR/action-items.md"
echo ""
echo "To run manually:    $VENV_DIR/bin/google-tasks-agent"
echo "To dry run:         $VENV_DIR/bin/google-tasks-agent --dry-run"
echo "To force run:       $VENV_DIR/bin/google-tasks-agent --force"
