#!/usr/bin/env bash
set -euo pipefail

# Google Tasks Agent - Uninstallation Script
# Supports macOS (launchd) and Linux (systemd)

CONFIG_DIR="$HOME/.google-tasks-agent"
OS="$(uname -s)"
USERNAME="$(whoami)"

echo "=== Google Tasks Agent Uninstaller ==="
echo ""

# Stop and remove scheduled agent
if [ "$OS" = "Darwin" ]; then
    PLIST_NAME="com.${USERNAME}.google-tasks-agent"
    PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

    if launchctl list "$PLIST_NAME" &>/dev/null 2>&1; then
        echo "Stopping launchd agent..."
        launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    fi

    if [ -f "$PLIST_PATH" ]; then
        echo "Removing plist: $PLIST_PATH"
        rm -f "$PLIST_PATH"
    fi

elif [ "$OS" = "Linux" ]; then
    SYSTEMD_DIR="$HOME/.config/systemd/user"

    if systemctl --user is-active google-tasks-agent.timer &>/dev/null 2>&1; then
        echo "Stopping systemd timer..."
        systemctl --user stop google-tasks-agent.timer 2>/dev/null || true
    fi

    if systemctl --user is-enabled google-tasks-agent.timer &>/dev/null 2>&1; then
        echo "Disabling systemd timer..."
        systemctl --user disable google-tasks-agent.timer 2>/dev/null || true
    fi

    for f in google-tasks-agent.service google-tasks-agent.timer; do
        if [ -f "$SYSTEMD_DIR/$f" ]; then
            echo "Removing: $SYSTEMD_DIR/$f"
            rm -f "$SYSTEMD_DIR/$f"
        fi
    done

    systemctl --user daemon-reload 2>/dev/null || true
fi

echo ""

# Remove venv
if [ -d "$CONFIG_DIR/venv" ]; then
    echo "Removing virtual environment: $CONFIG_DIR/venv"
    rm -rf "$CONFIG_DIR/venv"
fi

echo ""
echo "=== Uninstall Complete ==="
echo ""
echo "The scheduled agent has been stopped and removed."
echo ""
echo "Preserved (delete manually if desired):"
echo "  $CONFIG_DIR/state.json       — seen message IDs"
echo "  $CONFIG_DIR/action-items.md  — action items log"
echo "  $CONFIG_DIR/logs/            — log files"
echo ""
echo "To remove everything:  rm -rf $CONFIG_DIR"
