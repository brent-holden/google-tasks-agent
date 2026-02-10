"""Configuration constants and environment variable handling."""

import os
from pathlib import Path

# Platform detection
import platform

IS_MACOS = platform.system() == "Darwin"
IS_LINUX = platform.system() == "Linux"

# Configuration directory
CONFIG_DIR = Path.home() / ".google-tasks-agent"
STATE_FILE = CONFIG_DIR / "state.json"
ACTION_ITEMS_FILE = CONFIG_DIR / "action-items.md"
LOG_DIR = CONFIG_DIR / "logs"
LOG_FILE = LOG_DIR / "google-tasks-agent.log"

# MCP server path
GOOGLE_MCP_SERVER_PATH = os.environ.get(
    "GOOGLE_TASKS_AGENT_MCP_SERVER_PATH",
    str(Path.home() / "Code" / "google-mcp" / "dist" / "index.js"),
)

# Email configuration
MAX_EMAILS = int(os.environ.get("GOOGLE_TASKS_AGENT_MAX_EMAILS", "20"))
MAX_SEEN_IDS = 500

# Google Tasks configuration
TASKS_ENABLED = (
    os.environ.get("GOOGLE_TASKS_AGENT_TASKS_ENABLED", "true").lower() == "true"
)
TASKS_LIST_NAME = os.environ.get("GOOGLE_TASKS_AGENT_TASK_LIST", "Work Tasks")
TASKS_LIST_ID = os.environ.get("GOOGLE_TASKS_AGENT_TASK_LIST_ID", "")

# Calendar configuration
CALENDAR_LOOKAHEAD_DAYS = int(
    os.environ.get("GOOGLE_TASKS_AGENT_CALENDAR_DAYS", "28")
)
CALENDAR_ENABLED = (
    os.environ.get("GOOGLE_TASKS_AGENT_CALENDAR_ENABLED", "true").lower() == "true"
)

# Secondary calendar for direct task creation from events
FCTO_CALENDAR_ID = os.environ.get("GOOGLE_TASKS_AGENT_FCTO_CALENDAR_ID", "")
FCTO_CALENDAR_ENABLED = (
    os.environ.get("GOOGLE_TASKS_AGENT_FCTO_CALENDAR_ENABLED", "false").lower()
    == "true"
)

# Gemini meeting notes sender
GEMINI_NOTES_SENDER = "gemini-notes@google.com"

# Starred emails configuration
STARRED_EMAILS_ENABLED = (
    os.environ.get("GOOGLE_TASKS_AGENT_STARRED_ENABLED", "true").lower() == "true"
)
MAX_STARRED_EMAILS = int(os.environ.get("GOOGLE_TASKS_AGENT_MAX_STARRED", "20"))

# User email for name matching in Gemini notes
USER_EMAIL = os.environ.get("GOOGLE_TASKS_AGENT_USER_EMAIL", "")

# High-priority sender patterns (case-insensitive)
HIGH_PRIORITY_SENDERS = [
    "hr@", "human.resources@", "humanresources@", "people@", "peopleops@",
    "legal@", "compliance@", "ethics@",
    "finance@", "accounting@", "payroll@", "expenses@",
    "security@", "it-security@", "infosec@",
]

# Limits
CONTENT_LIMIT_DEFAULT = 2000
CONTENT_LIMIT_GEMINI = 4000
MAX_CALENDAR_IN_PROMPT = 30
MAX_ITEMS_IN_NOTIFICATION = 5

# Logging
LOG_MAX_BYTES = 5 * 1024 * 1024  # 5MB
LOG_BACKUP_COUNT = 3
