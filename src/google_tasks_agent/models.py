"""Data models for action items."""

from dataclasses import dataclass, asdict
from typing import Optional


@dataclass
class ActionItem:
    """Represents an action item extracted from an email or calendar event."""

    id: str
    subject: str
    sender: str
    priority: str  # HIGH, MEDIUM, LOW
    action: str
    notified_at: str
    due_date: Optional[str] = None  # YYYY-MM-DD
    create_task: bool = False
    task_created: bool = False
    source_type: str = "email"  # email, gemini_notes, calendar_prep, starred
    related_meeting: Optional[str] = None
    group: Optional[str] = None  # Parent group name if task was grouped

    def to_dict(self) -> dict:
        return asdict(self)
