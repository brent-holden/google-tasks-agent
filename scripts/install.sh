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
MCP_SERVER_DIR="$(dirname "$(dirname "$MCP_SERVER_PATH")")"
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

# --- Calendar discovery ---

SECONDARY_CALENDAR_IDS="${GOOGLE_TASKS_AGENT_SECONDARY_CALENDAR_IDS:-}"
SECONDARY_CALENDARS_ENABLED="false"
MAX_SECONDARY_CALENDARS=5

TOKENS_FILE="$MCP_SERVER_DIR/tokens.json"
CREDS_FILE="$MCP_SERVER_DIR/credentials/client_credentials.json"

if [ -z "$SECONDARY_CALENDAR_IDS" ] && [ -f "$TOKENS_FILE" ] && [ -f "$CREDS_FILE" ]; then
    echo "Fetching your Google Calendars..."
    echo ""

    # Use the MCP server's googleapis and auth to list calendars
    CALENDARS_JSON=$(node -e "
const {google} = require('$MCP_SERVER_DIR/node_modules/googleapis');
const fs = require('fs');
const tokens = JSON.parse(fs.readFileSync('$TOKENS_FILE'));
const raw = JSON.parse(fs.readFileSync('$CREDS_FILE'));
const c = raw.installed || raw.web;
const auth = new google.auth.OAuth2(c.client_id, c.client_secret);
auth.setCredentials(tokens);
const cal = google.calendar({version: 'v3', auth});
cal.calendarList.list({maxResults: 100}).then(r => {
    const items = (r.data.items || []).map(c => ({
        id: c.id,
        summary: c.summary || c.id,
        primary: c.primary || false,
        accessRole: c.accessRole
    }));
    console.log(JSON.stringify(items));
}).catch(e => {
    console.error('Failed to list calendars: ' + e.message);
    console.log('[]');
});
" 2>/dev/null) || CALENDARS_JSON="[]"

    CAL_COUNT=$(echo "$CALENDARS_JSON" | node -e "
const d = require('fs').readFileSync('/dev/stdin','utf8');
const items = JSON.parse(d);
console.log(items.length);
" 2>/dev/null) || CAL_COUNT=0

    if [ "$CAL_COUNT" -gt 0 ]; then
        echo "Available calendars:"
        echo ""

        # Display numbered list
        echo "$CALENDARS_JSON" | node -e "
const d = require('fs').readFileSync('/dev/stdin','utf8');
const items = JSON.parse(d);
items.forEach((c, i) => {
    const primary = c.primary ? ' (primary)' : '';
    const role = c.accessRole === 'owner' ? '' : ' [' + c.accessRole + ']';
    console.log('  ' + (i + 1) + ') ' + c.summary + primary + role);
});
"

        echo ""
        echo "The primary calendar is always used for context."
        echo "You can select up to $MAX_SECONDARY_CALENDARS additional calendars to auto-create tasks from their events."
        echo "Enter calendar numbers one at a time. Press Enter when done."
        echo ""

        SELECTED_IDS=()
        SELECTED_NAMES=()
        SELECTED_COUNT=0

        while [ "$SELECTED_COUNT" -lt "$MAX_SECONDARY_CALENDARS" ]; do
            REMAINING=$((MAX_SECONDARY_CALENDARS - SELECTED_COUNT))
            read -rp "Add calendar number ($REMAINING remaining, Enter to finish): " CAL_CHOICE

            # Empty input = done selecting
            [ -z "$CAL_CHOICE" ] && break

            # Validate number
            if ! [ "$CAL_CHOICE" -gt 0 ] 2>/dev/null || ! [ "$CAL_CHOICE" -le "$CAL_COUNT" ] 2>/dev/null; then
                echo "  Invalid choice. Enter a number between 1 and $CAL_COUNT."
                continue
            fi

            CAL_ID=$(echo "$CALENDARS_JSON" | node -e "
const d = require('fs').readFileSync('/dev/stdin','utf8');
const items = JSON.parse(d);
const idx = parseInt(process.argv[1]) - 1;
console.log(items[idx].id);
" "$CAL_CHOICE" 2>/dev/null) || CAL_ID=""

            if [ -z "$CAL_ID" ]; then
                echo "  Failed to read calendar. Try again."
                continue
            fi

            # Check for duplicates
            if [ "$SELECTED_COUNT" -gt 0 ]; then
                for existing in "${SELECTED_IDS[@]}"; do
                    if [ "$existing" = "$CAL_ID" ]; then
                        echo "  Already selected. Choose a different calendar."
                        CAL_ID=""
                        break
                    fi
                done
                [ -z "$CAL_ID" ] && continue
            fi

            CAL_NAME=$(echo "$CALENDARS_JSON" | node -e "
const d = require('fs').readFileSync('/dev/stdin','utf8');
const items = JSON.parse(d);
const idx = parseInt(process.argv[1]) - 1;
console.log(items[idx].summary);
" "$CAL_CHOICE" 2>/dev/null) || CAL_NAME="$CAL_ID"

            SELECTED_IDS+=("$CAL_ID")
            SELECTED_NAMES+=("$CAL_NAME")
            SELECTED_COUNT=$((SELECTED_COUNT + 1))
            echo "  Added: $CAL_NAME"
        done

        if [ "$SELECTED_COUNT" -gt 0 ]; then
            # Join IDs with commas
            SECONDARY_CALENDAR_IDS=$(IFS=,; echo "${SELECTED_IDS[*]}")
            SECONDARY_CALENDARS_ENABLED="true"
            echo ""
            echo "Selected $SELECTED_COUNT calendar(s):"
            for name in "${SELECTED_NAMES[@]}"; do
                echo "  - $name"
            done
        else
            echo "No additional calendars selected."
        fi
    else
        echo "Could not fetch calendars. You can set GOOGLE_TASKS_AGENT_SECONDARY_CALENDAR_IDS later."
    fi
elif [ -n "$SECONDARY_CALENDAR_IDS" ]; then
    SECONDARY_CALENDARS_ENABLED="true"
    echo "Using secondary calendars from environment: $SECONDARY_CALENDAR_IDS"
else
    echo "Skipping calendar discovery (MCP server not authenticated yet)."
    echo "You can set GOOGLE_TASKS_AGENT_SECONDARY_CALENDAR_IDS later."
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
        -e "s|{{SECONDARY_CALENDAR_IDS}}|${SECONDARY_CALENDAR_IDS:-}|g" \
        -e "s|{{SECONDARY_CALENDARS_ENABLED}}|${SECONDARY_CALENDARS_ENABLED}|g" \
        "$TEMPLATE" > "$PLIST_PATH"

    # Restrict plist permissions (contains API keys)
    chmod 600 "$PLIST_PATH"

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
        -e "s|{{SECONDARY_CALENDAR_IDS}}|${SECONDARY_CALENDAR_IDS:-}|g" \
        -e "s|{{SECONDARY_CALENDARS_ENABLED}}|${SECONDARY_CALENDARS_ENABLED}|g" \
        "$SERVICE_TEMPLATE" > "$SYSTEMD_DIR/google-tasks-agent.service"

    # Restrict service file permissions (contains API keys)
    chmod 600 "$SYSTEMD_DIR/google-tasks-agent.service"

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
    echo "Auth mode:            Vertex AI ($VERTEX_REGION / $VERTEX_PROJECT)"
else
    echo "Auth mode:            Anthropic API key"
fi
if [ "$SECONDARY_CALENDARS_ENABLED" = "true" ]; then
    echo "Secondary calendars:  $SECONDARY_CALENDAR_IDS"
else
    echo "Secondary calendars:  (none)"
fi
echo "Config dir:           $CONFIG_DIR"
echo "Logs dir:             $LOG_DIR"
echo "Action log:           $CONFIG_DIR/action-items.md"
echo ""
echo "To run manually:    $VENV_DIR/bin/google-tasks-agent"
echo "To dry run:         $VENV_DIR/bin/google-tasks-agent --dry-run"
echo "To force run:       $VENV_DIR/bin/google-tasks-agent --force"
