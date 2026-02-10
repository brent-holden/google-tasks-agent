"""Markdown action items log."""

import logging
from datetime import datetime

from .config import ACTION_ITEMS_FILE
from .models import ActionItem

logger = logging.getLogger("google-tasks-agent")


def append_to_action_log(action_items: list[ActionItem]) -> None:
    """Append new action items to the running markdown log."""
    if not action_items:
        return

    now = datetime.now().strftime("%Y-%m-%d %H:%M")

    if not ACTION_ITEMS_FILE.exists():
        with open(ACTION_ITEMS_FILE, "w") as f:
            f.write("# Email Action Items Log\n\n")
            f.write("This file tracks action items extracted from emails.\n\n")
            f.write("---\n\n")

    with open(ACTION_ITEMS_FILE, "a") as f:
        f.write(f"## {now}\n\n")

        for item in action_items:
            priority_badge = {"HIGH": "[!]", "MEDIUM": "[~]", "LOW": "[.]"}.get(
                item.priority, "[?]"
            )
            task_badge = (
                "[done]"
                if item.task_created
                else ("[task]" if item.create_task else "")
            )

            source_badges = {
                "gemini_notes": "[notes]",
                "calendar_prep": "[cal]",
                "starred": "[star]",
                "email": "[mail]",
            }
            source_badge = source_badges.get(item.source_type, "[mail]")

            f.write(
                f"- {priority_badge} {source_badge} **{item.priority}**: {item.action}\n"
            )
            f.write(f"  - From: {item.sender}\n")
            f.write(f"  - Subject: {item.subject}\n")
            if item.related_meeting:
                f.write(f"  - Meeting: {item.related_meeting}\n")
            if item.due_date:
                f.write(f"  - Due: {item.due_date}\n")
            if task_badge:
                status = (
                    "Created in Google Tasks"
                    if item.task_created
                    else "Flagged for Google Tasks (not created)"
                )
                f.write(f"  - {status}\n")
            f.write(f"  - Email ID: `{item.id}`\n\n")

        f.write("---\n\n")

    logger.info(f"Appended {len(action_items)} items to action log")
