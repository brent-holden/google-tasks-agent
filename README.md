# google-tasks-agent

AI-powered agent that scans Gmail and Google Calendar for action items and creates Google Tasks automatically. Uses the [Claude Agent SDK](https://pypi.org/project/claude-agent-sdk/) to orchestrate a Claude model that reads your email and calendar via MCP tools.

## How it works

Every 5 minutes (when scheduled), the agent:

1. Connects to the [google-mcp](https://github.com/brent-holden/google-mcp) server for Gmail, Calendar, and Tasks access
2. Fetches recent inbox emails, Gemini meeting notes, starred emails, and upcoming calendar events
3. Sends everything to Claude for analysis — it identifies action items, assigns priorities, infers due dates, and correlates emails with calendar events
4. Reconciles new action items against existing open tasks to avoid duplicates
5. Creates Google Tasks for high-priority items, starred emails, meeting action items, and anything with a deadline
6. Sends a desktop notification and appends to a markdown log
7. Tracks seen message IDs so it only processes new emails on subsequent runs

## Prerequisites

- **Python 3.11+**
- **Node.js** (for the MCP server)
- **Claude Code CLI** (`npm install -g @anthropic-ai/claude-code`)
- **Claude API access** — either an Anthropic API key (`ANTHROPIC_API_KEY`) or Google Vertex AI (`CLAUDE_CODE_USE_VERTEX` + `ANTHROPIC_VERTEX_REGION` + `ANTHROPIC_VERTEX_PROJECT_ID`)
- **google-mcp** server built and authenticated (see [Setup](#setup) below)

## Setup

### 1. Build the google-mcp server

The agent depends on the google-mcp MCP server for Google API access. If you haven't already:

```bash
cd ~/Code/google-mcp
npm install
npm run build
```

### 2. Authenticate google-mcp with Google

The MCP server needs OAuth credentials for Gmail, Calendar, Tasks, and Drive. On first run it will open a browser for Google OAuth consent:

```bash
cd ~/Code/google-mcp
npm start
```

This creates `tokens.json`. If you've recently added the Calendar scope, delete `tokens.json` first to force re-authentication:

```bash
rm tokens.json
npm start
```

### 3. Install the agent

**Option A: Automated install (with scheduling)**

```bash
cd ~/Code/google-tasks-agent
scripts/install.sh
```

The install script will:

1. **Detect authentication** — auto-detects Vertex AI or API key from your environment, or prompts you to choose
2. **Ask for your email** — used to match your name in Gemini meeting note action items
3. **Discover calendars** — uses the MCP server's existing Google OAuth tokens to fetch your calendars and lets you pick up to 5 additional calendars for automatic task creation from their events
4. **Install the package** — creates a virtual environment at `~/.google-tasks-agent/venv/`
5. **Set up scheduling** — configures a launchd agent (macOS) or systemd timer (Linux) to run every 5 minutes

For non-interactive install, pass config via environment variables:

```bash
CLAUDE_CODE_USE_VERTEX=1 \
ANTHROPIC_VERTEX_REGION=us-east5 \
ANTHROPIC_VERTEX_PROJECT_ID=your-project-id \
GOOGLE_TASKS_AGENT_USER_EMAIL=you@example.com \
GOOGLE_TASKS_AGENT_SECONDARY_CALENDAR_IDS=cal1@group.calendar.google.com,cal2@group.calendar.google.com \
scripts/install.sh
```

**Option B: Manual install**

```bash
cd ~/Code/google-tasks-agent
python3 -m venv ~/.google-tasks-agent/venv
~/.google-tasks-agent/venv/bin/pip install .
```

## Usage

```bash
# Full run — scan emails, create tasks, update state, send notifications
google-tasks-agent

# Dry run — scan and analyze without creating tasks or updating state
google-tasks-agent --dry-run

# Force run — process all emails, ignoring previously-seen state
google-tasks-agent --force
```

If installed via the install script, the agent runs automatically every 5 minutes.

### Managing the scheduled agent

**macOS (launchd):**

```bash
# Check status
launchctl list | grep google-tasks-agent

# Stop
launchctl bootout gui/$(id -u)/com.$(whoami).google-tasks-agent

# Start
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.$(whoami).google-tasks-agent.plist
```

**Linux (systemd):**

```bash
# Check status
systemctl --user status google-tasks-agent.timer

# View logs
journalctl --user -u google-tasks-agent

# Stop
systemctl --user stop google-tasks-agent.timer

# Disable
systemctl --user disable google-tasks-agent.timer
```

### Uninstalling

```bash
cd ~/Code/google-tasks-agent
scripts/uninstall.sh
```

This stops and removes the scheduled agent and deletes the virtual environment. Your state, action items log, and logs are preserved — delete `~/.google-tasks-agent/` manually to remove them.

## Configuration

All configuration is via environment variables. Set them in your shell profile, or they'll be baked into the launchd/systemd config by the install script.

### Authentication (one of the two options)

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | *(empty)* | Anthropic API key (direct API access) |
| `CLAUDE_CODE_USE_VERTEX` | *(empty)* | Set to `1` to use Google Vertex AI |
| `ANTHROPIC_VERTEX_REGION` | *(empty)* | Vertex AI region (e.g. `us-east5`) |
| `ANTHROPIC_VERTEX_PROJECT_ID` | *(empty)* | Vertex AI project ID |

Vertex AI also requires [Application Default Credentials](https://cloud.google.com/docs/authentication/application-default-credentials) (`gcloud auth application-default login`).

### Agent settings

| Variable | Default | Description |
|---|---|---|
| `GOOGLE_TASKS_AGENT_MCP_SERVER_PATH` | `~/Code/google-mcp/dist/index.js` | Path to the compiled MCP server |
| `GOOGLE_TASKS_AGENT_USER_EMAIL` | *(empty)* | Your email address, used to match your name in Gemini meeting notes |
| `GOOGLE_TASKS_AGENT_MAX_EMAILS` | `20` | Number of inbox emails to fetch per run |
| `GOOGLE_TASKS_AGENT_TASKS_ENABLED` | `true` | Enable/disable Google Task creation |
| `GOOGLE_TASKS_AGENT_TASK_LIST` | `Work Tasks` | Name of the Google Tasks list to use |
| `GOOGLE_TASKS_AGENT_TASK_LIST_ID` | *(empty)* | Direct task list ID (overrides name lookup) |
| `GOOGLE_TASKS_AGENT_CALENDAR_ENABLED` | `true` | Include calendar events as context |
| `GOOGLE_TASKS_AGENT_CALENDAR_DAYS` | `28` | Number of days to look ahead in calendar |
| `GOOGLE_TASKS_AGENT_SECONDARY_CALENDAR_IDS` | *(empty)* | Comma-separated calendar IDs for direct task creation from events (up to 5) |
| `GOOGLE_TASKS_AGENT_SECONDARY_CALENDARS_ENABLED` | `false` | Enable secondary calendar task creation (requires calendar IDs) |
| `GOOGLE_TASKS_AGENT_STARRED_ENABLED` | `true` | Process starred emails |
| `GOOGLE_TASKS_AGENT_MAX_STARRED` | `20` | Number of starred emails to fetch |

## Files and directories

| Path | Purpose |
|---|---|
| `~/.google-tasks-agent/state.json` | Tracks seen message IDs and last check time |
| `~/.google-tasks-agent/action-items.md` | Running markdown log of all extracted action items |
| `~/.google-tasks-agent/logs/` | Rotating log files |
| `~/.google-tasks-agent/venv/` | Python virtual environment (created by install script) |

## Action item detection

The agent creates tasks automatically when any of these conditions are met:

- **HIGH priority** emails
- Emails from **HR, Legal, Finance, or Security**
- Emails with a **specific deadline** mentioned
- **Starred emails** (always creates a task)
- **Gemini meeting notes** with action items assigned to you
- Emails requiring **preparation for an upcoming calendar event**
- **Concur expense reports** requiring your approval

The agent skips newsletters, FYI notifications, action items assigned to other people, and generic automated alerts.

### Duplicate reconciliation

Before creating new tasks, the agent fetches all open tasks from your Google Tasks list and checks for duplicates. A new action item is considered a duplicate if an existing task's title overlaps significantly with the new action text, or if the existing task's notes reference the same email ID. Duplicates are skipped and reported in the run summary.

## Project structure

```
google-tasks-agent/
├── pyproject.toml                    # Package configuration
├── src/
│   └── google_tasks_agent/
│       ├── __init__.py
│       ├── agent.py                  # Entry point, Claude Agent SDK orchestration
│       ├── config.py                 # Environment variables and constants
│       ├── models.py                 # ActionItem dataclass
│       ├── state.py                  # State persistence (seen IDs, atomic writes)
│       ├── prompt.py                 # System prompt builder
│       ├── notifications.py          # Desktop notifications (macOS/Linux)
│       └── action_log.py            # Markdown action log
├── templates/
│   ├── com.user.google-tasks-agent.plist.template   # macOS launchd
│   ├── google-tasks-agent.service.template          # Linux systemd service
│   └── google-tasks-agent.timer.template            # Linux systemd timer
└── scripts/
    ├── install.sh                    # Cross-platform installer
    └── uninstall.sh                  # Cross-platform uninstaller
```
