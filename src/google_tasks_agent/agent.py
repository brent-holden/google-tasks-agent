"""Main entry point and agent orchestration."""

import argparse
import asyncio
import json
import logging
import sys
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler

from claude_agent_sdk import ClaudeAgentOptions, ResultMessage, query

from .action_log import append_to_action_log
from .config import (
    CONFIG_DIR,
    GOOGLE_MCP_SERVER_PATH,
    HIGH_PRIORITY_SENDERS,
    LOG_BACKUP_COUNT,
    LOG_DIR,
    LOG_FILE,
    LOG_MAX_BYTES,
)
from .models import ActionItem
from .notifications import send_notification
from .prompt import build_system_prompt
from .state import load_state, save_state


def setup_logging(dry_run: bool = False) -> logging.Logger:
    """Configure logging to both file and stderr."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    logger = logging.getLogger("google-tasks-agent")
    logger.handlers.clear()
    logger.setLevel(logging.DEBUG if dry_run else logging.INFO)

    file_format = logging.Formatter(
        "%(asctime)s - %(levelname)s - %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    )

    file_handler = RotatingFileHandler(
        LOG_FILE, maxBytes=LOG_MAX_BYTES, backupCount=LOG_BACKUP_COUNT
    )
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(file_format)
    logger.addHandler(file_handler)

    stderr_handler = logging.StreamHandler(sys.stderr)
    stderr_handler.setLevel(logging.INFO)
    stderr_handler.setFormatter(file_format)
    logger.addHandler(stderr_handler)

    return logger


def parse_action_items(result: dict) -> list[ActionItem]:
    """Parse the agent's structured result into ActionItem objects."""
    now = datetime.now(timezone.utc).isoformat()
    items = []

    for item_data in result.get("action_items", []):
        sender = item_data.get("sender", "(unknown)").lower()
        priority = item_data.get("priority", "MEDIUM")
        source_type = item_data.get("source_type", "email")
        create_task = item_data.get("create_task", False)

        # Force task creation for high priority or special senders
        if not create_task and priority == "HIGH":
            create_task = True
        if not create_task and source_type == "gemini_notes":
            create_task = True
        if not create_task and source_type == "starred":
            create_task = True
        if not create_task:
            for pattern in HIGH_PRIORITY_SENDERS:
                if pattern in sender:
                    create_task = True
                    break

        items.append(
            ActionItem(
                id=item_data.get("id", ""),
                subject=item_data.get("subject", "(unknown)"),
                sender=item_data.get("sender", "(unknown)"),
                priority=priority,
                action=item_data.get("action", ""),
                notified_at=now,
                due_date=item_data.get("due_date"),
                create_task=create_task,
                task_created=item_data.get("task_created", False),
                source_type=source_type,
                related_meeting=item_data.get("related_meeting"),
            )
        )

    return items


def _extract_json(text: str) -> dict:
    """Extract JSON from text that may contain markdown code blocks."""
    if "```json" in text:
        start = text.find("```json") + 7
        end = text.find("```", start)
        if end != -1:
            text = text[start:end].strip()
    elif "```" in text:
        start = text.find("```") + 3
        end = text.find("```", start)
        if end != -1:
            text = text[start:end].strip()
    elif "{" in text:
        start = text.find("{")
        end = text.rfind("}") + 1
        if end > start:
            text = text[start:end]

    return json.loads(text)


async def run_agent(
    dry_run: bool = False, force: bool = False, logger: logging.Logger | None = None
) -> None:
    """Run the agent workflow."""
    if logger is None:
        logger = logging.getLogger("google-tasks-agent")

    # Load state
    state = load_state()
    seen_message_ids = state.get("seen_message_ids", [])
    seen_secondary_event_ids = state.get("seen_secondary_event_ids", [])
    logger.info(f"Loaded {len(seen_message_ids)} previously seen message IDs")

    # Build system prompt
    system_prompt = build_system_prompt(
        seen_message_ids=seen_message_ids,
        seen_secondary_event_ids=seen_secondary_event_ids,
        dry_run=dry_run,
        force=force,
    )

    logger.info("Starting agent with MCP server...")

    options = ClaudeAgentOptions(
        system_prompt=system_prompt,
        mcp_servers={
            "google": {
                "command": "node",
                "args": [GOOGLE_MCP_SERVER_PATH],
            },
        },
        allowed_tools=["mcp__google__*"],
        permission_mode="bypassPermissions",
        max_turns=50,
        output_format={
            "type": "json_schema",
            "schema": {
                "type": "object",
                "properties": {
                    "processed_message_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                    },
                    "processed_secondary_event_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                    },
                    "action_items": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "id": {"type": "string"},
                                "subject": {"type": "string"},
                                "sender": {"type": "string"},
                                "priority": {
                                    "type": "string",
                                    "enum": ["HIGH", "MEDIUM", "LOW"],
                                },
                                "action": {"type": "string"},
                                "due_date": {"type": ["string", "null"]},
                                "create_task": {"type": "boolean"},
                                "task_created": {"type": "boolean"},
                                "source_type": {
                                    "type": "string",
                                    "enum": [
                                        "email",
                                        "gemini_notes",
                                        "calendar_prep",
                                        "starred",
                                    ],
                                },
                                "related_meeting": {"type": ["string", "null"]},
                            },
                            "required": [
                                "id",
                                "subject",
                                "sender",
                                "priority",
                                "action",
                                "create_task",
                                "task_created",
                                "source_type",
                            ],
                        },
                    },
                    "summary": {
                        "type": "object",
                        "properties": {
                            "emails_scanned": {"type": "integer"},
                            "action_items_found": {"type": "integer"},
                            "tasks_created": {"type": "integer"},
                            "duplicates_skipped": {"type": "integer"},
                            "secondary_tasks_created": {"type": "integer"},
                        },
                        "required": [
                            "emails_scanned",
                            "action_items_found",
                            "tasks_created",
                            "duplicates_skipped",
                            "secondary_tasks_created",
                        ],
                    },
                },
                "required": [
                    "processed_message_ids",
                    "processed_secondary_event_ids",
                    "action_items",
                    "summary",
                ],
            },
        },
    )

    result_data = None

    async for message in query(prompt="Execute the workflow.", options=options):
        if isinstance(message, ResultMessage):
            if message.is_error:
                logger.error(f"Agent returned error: {message.result}")
                return

            result_text = message.result
            if result_text:
                try:
                    result_data = _extract_json(result_text)
                except json.JSONDecodeError:
                    logger.error(f"Failed to parse agent result as JSON")
                    logger.debug(f"Raw result: {result_text[:500]}")
                    return

            # Also check structured_output
            if result_data is None and hasattr(message, "structured_output") and message.structured_output:
                result_data = message.structured_output

    if result_data is None:
        logger.error("Agent did not return a result")
        return

    # Log summary
    summary = result_data.get("summary", {})
    logger.info(
        f"Agent completed: scanned={summary.get('emails_scanned', 0)}, "
        f"items={summary.get('action_items_found', 0)}, "
        f"tasks={summary.get('tasks_created', 0)}, "
        f"duplicates_skipped={summary.get('duplicates_skipped', 0)}, "
        f"secondary_tasks={summary.get('secondary_tasks_created', 0)}"
    )

    # Parse action items
    action_items = parse_action_items(result_data)

    if action_items:
        logger.info(f"Processed {len(action_items)} action items")

        # Log by source type
        by_source: dict[str, int] = {}
        for a in action_items:
            by_source[a.source_type] = by_source.get(a.source_type, 0) + 1
        for src, count in by_source.items():
            logger.info(f"  - {src}: {count}")

    if not dry_run:
        # Send notification
        if action_items:
            send_notification(action_items)
            append_to_action_log(action_items)

        # Update state with new seen IDs
        new_msg_ids = result_data.get("processed_message_ids", [])
        new_secondary_ids = result_data.get("processed_secondary_event_ids", [])

        state["seen_message_ids"] = list(
            set(seen_message_ids) | set(new_msg_ids)
        )
        state["seen_secondary_event_ids"] = list(
            set(seen_secondary_event_ids) | set(new_secondary_ids)
        )
        state["last_check"] = datetime.now(timezone.utc).isoformat()
        state["last_action_items"] = [item.to_dict() for item in action_items]

        save_state(state)
        logger.info("State saved")
    else:
        logger.info("DRY RUN: State not updated")

    logger.info("Google Tasks Agent completed successfully")


def main():
    """CLI entry point."""
    parser = argparse.ArgumentParser(description="Google Tasks Agent")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Run without creating tasks or updating state",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Process all emails, ignoring seen state",
    )
    args = parser.parse_args()

    logger = setup_logging(dry_run=args.dry_run)
    logger.info("=" * 50)
    logger.info("Google Tasks Agent starting...")

    if args.dry_run:
        logger.info("DRY RUN MODE - no tasks created, no state updated")
    if args.force:
        logger.info("FORCE MODE - processing all emails")

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    try:
        asyncio.run(run_agent(dry_run=args.dry_run, force=args.force, logger=logger))
    except KeyboardInterrupt:
        logger.info("Interrupted by user")
    except Exception as e:
        logger.error(f"Agent failed: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
