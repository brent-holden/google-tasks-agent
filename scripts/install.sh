#!/usr/bin/env bash
set -euo pipefail

# Google Tasks Agent - Installation Script
# Supports macOS (launchd) and Linux (systemd)
# Supports both Anthropic API key and Google Vertex AI authentication

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

# --- Authentication setup ---

# Auto-detect Vertex AI from environment
VERTEX_REGION="${ANTHROPIC_VERTEX_REGION:-}"
VERTEX_PROJECT="${ANTHROPIC_VERTEX_PROJECT_ID:-}"
USE_VERTEX="${CLAUDE_CODE_USE_VERTEX:-}"
API_KEY="${ANTHROPIC_API_KEY:-}"

if [ -n "$USE_VERTEX" ] && [ -n "$VERTEX_REGION" ] && [ -n "$VERTEX_PROJECT" ]; then
    echo "Detected Vertex AI configuration from environment:"
    echo "  Region:  $VERTEX_REGION"
    echo "  Project: $VERTEX_PROJECT"
    AUTH_MODE="vertex"
elif [ -n "$API_KEY" ]; then
    echo "Detected Anthropic API key from environment."
    AUTH_MODE="apikey"
else
    echo "Choose authentication method:"
    echo "  1) Google Vertex AI (CLAUDE_CODE_USE_VERTEX)"
    echo "  2) Anthropic API key (ANTHROPIC_API_KEY)"
    read -rp "Enter 1 or 2: " AUTH_CHOICE

    if [ "$AUTH_CHOICE" = "1" ]; then
        AUTH_MODE="vertex"
        USE_VERTEX="1"
        read -rp "Vertex AI region (e.g. us-east5): " VERTEX_REGION
        read -rp "Vertex AI project ID: " VERTEX_PROJECT

        if [ -z "$VERTEX_REGION" ] || [ -z "$VERTEX_PROJECT" ]; then
            echo "Error: Region and project ID are required for Vertex AI."
            exit 1
        fi

        # Check for ADC
        ADC_PATH="$HOME/.config/gcloud/application_default_credentials.json"
        if [ ! -f "$ADC_PATH" ]; then
            echo "Warning: Application Default Credentials not found at $ADC_PATH"
            echo "Run: gcloud auth application-default login"
        fi
    else
        AUTH_MODE="apikey"
        read -rp "Anthropic API key: " API_KEY
        if [ -z "$API_KEY" ]; then
            echo "Warning: No API key provided. Set ANTHROPIC_API_KEY before running."
        fi
    fi
fi

echo ""

# Prompt for user email
if [ -z "${GOOGLE_TASKS_AGENT_USER_EMAIL:-}" ]; then
    read -rp "Your email address (for name matching in Gemini notes, or Enter to skip): " USER_EMAIL
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
        -e "s|{{ANTHROPIC_API_KEY}}|${API_KEY:-}|g" \
        -e "s|{{CLAUDE_CODE_USE_VERTEX}}|${USE_VERTEX:-}|g" \
        -e "s|{{ANTHROPIC_VERTEX_REGION}}|${VERTEX_REGION:-}|g" \
        -e "s|{{ANTHROPIC_VERTEX_PROJECT_ID}}|${VERTEX_PROJECT:-}|g" \
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
        -e "s|{{ANTHROPIC_API_KEY}}|${API_KEY:-}|g" \
        -e "s|{{CLAUDE_CODE_USE_VERTEX}}|${USE_VERTEX:-}|g" \
        -e "s|{{ANTHROPIC_VERTEX_REGION}}|${VERTEX_REGION:-}|g" \
        -e "s|{{ANTHROPIC_VERTEX_PROJECT_ID}}|${VERTEX_PROJECT:-}|g" \
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
if [ "$AUTH_MODE" = "vertex" ]; then
    echo "Auth mode:   Vertex AI ($VERTEX_REGION / $VERTEX_PROJECT)"
else
    echo "Auth mode:   Anthropic API key"
fi
echo "Config dir:  $CONFIG_DIR"
echo "Logs dir:    $LOG_DIR"
echo "Action log:  $CONFIG_DIR/action-items.md"
echo ""
echo "To run manually:    $VENV_DIR/bin/google-tasks-agent"
echo "To dry run:         $VENV_DIR/bin/google-tasks-agent --dry-run"
echo "To force run:       $VENV_DIR/bin/google-tasks-agent --force"
