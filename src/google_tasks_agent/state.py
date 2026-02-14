"""State management for tracking seen messages and events."""

import json
import os
import tempfile
from pathlib import Path

from .config import CONFIG_DIR, STATE_FILE, MAX_SEEN_IDS


def load_state() -> dict:
    """Load the state file or return default state."""
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE) as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass

    return {
        "seen_message_ids": [],
        "seen_secondary_event_ids": [],
        "last_check": None,
        "last_action_items": [],
    }


def save_state(state: dict) -> None:
    """Save state to file atomically, keeping only recent IDs."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    # Restrict config directory to owner only (contains PII from emails)
    os.chmod(CONFIG_DIR, 0o700)

    # Limit the number of stored IDs to prevent unbounded growth
    if len(state.get("seen_message_ids", [])) > MAX_SEEN_IDS:
        state["seen_message_ids"] = state["seen_message_ids"][-MAX_SEEN_IDS:]

    if len(state.get("seen_secondary_event_ids", [])) > MAX_SEEN_IDS:
        state["seen_secondary_event_ids"] = state["seen_secondary_event_ids"][-MAX_SEEN_IDS:]

    # Write to temp file and atomically rename to prevent corruption
    with tempfile.NamedTemporaryFile(
        "w", dir=CONFIG_DIR, delete=False, suffix=".json"
    ) as f:
        json.dump(state, f, indent=2)
        temp_path = Path(f.name)
    # Restrict state file to owner only before moving into place
    os.chmod(temp_path, 0o600)
    temp_path.rename(STATE_FILE)
