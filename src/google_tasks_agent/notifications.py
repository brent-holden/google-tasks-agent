"""Desktop notifications for action items."""

import logging
import subprocess

from .config import IS_MACOS, IS_LINUX, MAX_ITEMS_IN_NOTIFICATION
from .models import ActionItem

logger = logging.getLogger("google-tasks-agent")


def send_notification(action_items: list[ActionItem]) -> None:
    """Send desktop notification with action items summary."""
    if not action_items:
        return

    count = len(action_items)
    title = f"Email Action Items ({count} new)"

    priority_icons = {"HIGH": "[!]", "MEDIUM": "[~]", "LOW": "[.]"}

    lines = []
    for item in action_items[:MAX_ITEMS_IN_NOTIFICATION]:
        icon = priority_icons.get(item.priority, "[?]")
        action_text = (
            item.action[:50] + "..." if len(item.action) > 50 else item.action
        )
        lines.append(f"{icon} {item.priority}: {action_text}")

        sender = item.sender.split("<")[0].strip()[:30]
        lines.append(f"   From: {sender}")

    if count > MAX_ITEMS_IN_NOTIFICATION:
        lines.append(f"   ... and {count - MAX_ITEMS_IN_NOTIFICATION} more")

    message = "\n".join(lines)

    try:
        if IS_MACOS:
            safe_message = (
                message.replace("\\", "\\\\")
                .replace('"', '\\"')
                .replace("\n", "\\n")
            )
            safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
            script = f'display notification "{safe_message}" with title "{safe_title}" sound name "Glass"'
            subprocess.run(
                ["osascript", "-e", script],
                capture_output=True,
                timeout=10,
            )
        elif IS_LINUX:
            short_message = (
                f"{count} action items found. "
                f"Check ~/.google-tasks-agent/action-items.md"
            )
            subprocess.run(
                [
                    "notify-send",
                    "--urgency=normal",
                    "--app-name=Google Tasks Agent",
                    title,
                    short_message,
                ],
                capture_output=True,
                timeout=10,
            )
        else:
            logger.warning(f"Notifications not supported on this platform")
            return

        logger.info(f"Sent notification for {count} action items")
    except FileNotFoundError as e:
        logger.warning(f"Notification command not found: {e}")
    except Exception as e:
        logger.error(f"Failed to send notification: {e}")
