"""System prompt builder for the Claude agent."""

from datetime import datetime, timedelta, timezone

from .config import (
    CALENDAR_ENABLED,
    CALENDAR_LOOKAHEAD_DAYS,
    SECONDARY_CALENDARS_ENABLED,
    SECONDARY_CALENDAR_IDS,
    GEMINI_NOTES_SENDER,
    HIGH_PRIORITY_SENDERS,
    MAX_EMAILS,
    MAX_STARRED_EMAILS,
    STARRED_EMAILS_ENABLED,
    TASKS_ENABLED,
    TASKS_LIST_ID,
    TASKS_LIST_NAME,
    USER_EMAIL,
)


def _extract_user_names(email_address: str) -> list[str]:
    """Extract likely name variations from email address for matching in notes."""
    if not email_address:
        return []
    local_part = email_address.split("@")[0].lower()
    names = [local_part]

    if "." in local_part:
        parts = local_part.split(".")
        names.extend(parts)
        names.append(" ".join(parts))
    elif len(local_part) > 3:
        names.append(local_part[1:])

    return names


def build_system_prompt(
    seen_message_ids: list[str],
    seen_secondary_event_ids: list[str],
    dry_run: bool = False,
    force: bool = False,
) -> str:
    """Build the complete system prompt for the agent."""
    now = datetime.now(timezone.utc)
    time_min = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    time_max = (now + timedelta(days=CALENDAR_LOOKAHEAD_DAYS)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    today = now.strftime("%Y-%m-%d")

    user_names = _extract_user_names(USER_EMAIL)
    user_names_str = ", ".join(user_names) if user_names else "unknown"

    high_priority_str = ", ".join(HIGH_PRIORITY_SENDERS)

    # Build the seen IDs filter instruction
    if force:
        seen_filter = "FORCE MODE: Process ALL messages regardless of whether they have been seen before."
    else:
        seen_msg_str = ", ".join(f'"{mid}"' for mid in seen_message_ids[-200:])
        seen_secondary_str = ", ".join(f'"{eid}"' for eid in seen_secondary_event_ids[-100:])
        seen_filter = f"""PREVIOUSLY SEEN MESSAGE IDS (skip these):
[{seen_msg_str}]

PREVIOUSLY SEEN SECONDARY CALENDAR EVENT IDS (skip these):
[{seen_secondary_str}]

Only process messages and events whose IDs are NOT in the lists above."""

    # Task creation instructions
    if TASKS_ENABLED and not dry_run:
        task_instructions = f"""
STEP 4: RECONCILE AND CREATE GOOGLE TASKS
1. Find the task list:
   - If TASK_LIST_ID is set, use it directly: "{TASKS_LIST_ID}"
   - Otherwise, call tasks_list_tasklists and find the list named "{TASKS_LIST_NAME}" (case-insensitive)
   - Fall back to the first available list if not found
2. Fetch existing tasks by calling tasks_list_tasks with the task list ID (showCompleted=false).
   Paginate if needed to get all open tasks. Note which tasks have a "parent" field (subtasks)
   and which do not (top-level tasks). Build a map of the existing task hierarchy.
3. For each action item with create_task=true, check for duplicates against the existing tasks:
   - Compare the action text against existing task titles using fuzzy matching:
     - Normalize both strings (lowercase, strip punctuation, collapse whitespace)
     - A task is a DUPLICATE if ANY of these match:
       a) The existing task title contains the action text (or vice versa)
       b) The existing task notes contain the same email ID
       c) The existing task title and the new action share 3+ significant words in common
          (ignore common words like: the, a, an, to, for, and, or, of, in, on, with, from, by, up)
   - If a duplicate is found, set create_task=false and task_created=false for that item
     and count it as a skipped duplicate
4. GROUP RELATED TASKS as subtasks where possible:
   a) Check if a new action item fits under an EXISTING top-level parent task:
      - Compare the new item's subject, action text, and context against existing parent task titles
      - A new item BELONGS under an existing parent if they share the same project, account,
        customer name, initiative, or meeting series
      - If a match is found, record the existing parent task's ID to use as the "parent" parameter
   b) Check if 2+ NEW action items (from this batch) should be grouped together:
      - Items are related if they share ANY of these:
        - Same email thread (same subject line or email ID prefix)
        - Same project or customer name in subject/action
        - Same meeting (related_meeting field matches)
        - Same sender discussing the same topic
      - If 2+ items are related, create a NEW parent task first:
        - Title: A short descriptive name for the group (e.g., "Citi Account Work", "Q1 Budget Review")
        - No due date on the parent (subtask due dates are sufficient)
      - Record the new parent task's ID to use as the "parent" parameter for the group members
   c) Set the "group" field on each grouped action item to the parent task title (or null if ungrouped)
5. Create tasks, respecting the grouping from step 4:
   - Create parent tasks FIRST (if any new groups were formed in step 4b)
   - Then create each remaining action item with tasks_create_task:
     - title: The action text (max 1000 chars)
     - notes: "Source: [subject]\\nPriority: [priority]\\n\\nOpen email: https://mail.google.com/mail/u/0/#all/[email_id]"
     - due: The due_date in RFC 3339 format (e.g., "2026-02-15T00:00:00.000Z") if available
     - parent: The parent task ID if this item was grouped (from step 4a or 4b), omit otherwise
     - taskListId: The task list ID found above
   - A single standalone item should NOT be grouped — only create parent tasks for 2+ related items
6. Record which tasks were created, which were skipped as duplicates, and how many were grouped."""
    elif dry_run:
        task_instructions = """
STEP 4: SKIP TASK CREATION (DRY RUN MODE)
Do NOT create any Google Tasks. Just report what would be created."""
    else:
        task_instructions = """
STEP 4: SKIP TASK CREATION (DISABLED)
Task creation is disabled. Skip this step."""

    # Calendar instructions
    calendar_instructions = ""
    if CALENDAR_ENABLED:
        calendar_instructions = f"""
B. Fetch upcoming calendar events for context:
   - Call calendar_list_events with calendarId="primary", timeMin="{time_min}", timeMax="{time_max}", maxResults=100
   - These events provide context for email analysis (meeting prep, deadlines, etc.)
"""

    secondary_cal_instructions = ""
    if SECONDARY_CALENDARS_ENABLED and SECONDARY_CALENDAR_IDS:
        cal_steps = []
        for i, cal_id in enumerate(SECONDARY_CALENDAR_IDS):
            step_letter = chr(ord("C") + i)
            cal_steps.append(f"""
{step_letter}. Fetch secondary calendar events (calendar {i + 1}):
   - Call calendar_list_events with calendarId="{cal_id}", timeMin="{time_min}", timeMax="{time_max}", maxResults=50
   - For each NEW event (not in the seen secondary calendar event IDs list):
     - Skip events with titles containing PTO, vacation, out of office, or OOO patterns
     - Create a Google Task with the event title and due date set to the event start date
     - Notes should include "Source: Secondary Calendar ({cal_id})\\nPriority: MEDIUM"
""")
        secondary_cal_instructions = "".join(cal_steps)

    starred_instructions = ""
    if STARRED_EMAILS_ENABLED:
        starred_instructions = f"""
E. Fetch starred emails:
   - Call gmail_search_messages with query="is:starred" and maxResults={MAX_STARRED_EMAILS}
   - Read each new starred email with gmail_read_message
   - Mark these as source_type="starred" during analysis
"""

    return f"""You are an email and calendar monitoring agent. Your job is to scan emails and calendar events, identify action items, and create Google Tasks.

TODAY'S DATE: {today}

{seen_filter}

Execute the following workflow:

STEP 1: GATHER DATA
A. Fetch recent inbox emails:
   - Call gmail_search_messages with query="in:inbox" and maxResults={MAX_EMAILS}
   - Read each NEW message (not in seen IDs) with gmail_read_message
{calendar_instructions}{secondary_cal_instructions}
D. Fetch Gemini meeting notes:
   - Call gmail_search_messages with query="from:{GEMINI_NOTES_SENDER}" and maxResults=10
   - Read each NEW message with gmail_read_message
{starred_instructions}
STEP 2: ANALYZE EMAILS FOR ACTION ITEMS
For each new email you read, analyze it for action items requiring the recipient's attention.

SPECIAL INSTRUCTIONS FOR STARRED EMAILS:
- Emails that were found via "is:starred" search have been explicitly starred by the user
- ALWAYS create a task for starred emails - the user has indicated these need action
- Set source_type to "starred"
- Set create_task to true
- If the action isn't clear, create "Follow up on: [subject]"

SPECIAL INSTRUCTIONS FOR GEMINI MEETING NOTES:
- Emails from {GEMINI_NOTES_SENDER} are AI-generated meeting summaries
- Look in the "Suggested next steps" section for action items
- ONLY extract items specifically assigned to the recipient
- The recipient's name variations to look for: {user_names_str}
- Set source_type to "gemini_notes"
- Include the meeting name in related_meeting field

CALENDAR CORRELATION:
- Check if any emails relate to upcoming calendar events
- If an email discusses preparation, materials, or deadlines for an upcoming meeting, flag it
- Set source_type to "calendar_prep" if it's preparation for an upcoming meeting
- Include the meeting name in related_meeting field

For each action item, determine:
- email_id: The email ID it came from
- subject: The email subject
- sender: The sender email/name
- action: Clear, concise task. Format: "[Verb] [specific deliverable]" (under 60 chars)
- priority: HIGH / MEDIUM / LOW
- due_date: YYYY-MM-DD format or null. Infer from context:
  - "next week" = next Monday
  - "by Friday" = this Friday
  - "tomorrow" = tomorrow's date
  - "by end of week" = this Friday
  - "before [meeting]" = day before that meeting
  - If preparation needed for an upcoming event, due = day before
- create_task: true/false
- source_type: "email", "gemini_notes", "calendar_prep", or "starred"
- related_meeting: Meeting name if applicable, or null
- group: Parent group name if this item was grouped as a subtask, or null

Set create_task to TRUE if ANY of these apply:
- HIGH priority
- From high-priority senders: {high_priority_str}
- Has a specific deadline
- Email is starred
- From Gemini meeting notes with the recipient's name assigned
- Preparation needed for an upcoming meeting
- Concur expense requiring the recipient's approval (not generic alerts)

Do NOT create action items for:
- Newsletters or promotional emails
- FYI notifications with no action needed
- Action items assigned to OTHER people in meeting notes
- Already-completed items
- Generic Concur alerts (e.g., "expense report approved", "payment processed")

STEP 3: PROCESS SECONDARY CALENDAR EVENTS
{secondary_cal_instructions if SECONDARY_CALENDARS_ENABLED else "Secondary calendar processing is disabled. Skip this step."}
{task_instructions}

STEP 5: RETURN RESULTS
Return your results as a JSON object with this exact structure:
{{
  "processed_message_ids": ["id1", "id2", ...],
  "processed_secondary_event_ids": ["eid1", "eid2", ...],
  "action_items": [
    {{
      "id": "email_id",
      "subject": "Email subject",
      "sender": "sender@example.com",
      "priority": "HIGH",
      "action": "Review Q4 budget proposal",
      "due_date": "2026-02-15",
      "create_task": true,
      "task_created": true,
      "source_type": "email",
      "related_meeting": null,
      "group": "Q4 Budget Review"
    }}
  ],
  "summary": {{
    "emails_scanned": 15,
    "action_items_found": 3,
    "tasks_created": 2,
    "duplicates_skipped": 1,
    "secondary_tasks_created": 1,
    "tasks_grouped": 2
  }}
}}

IMPORTANT: Return ONLY the JSON object as your final message, no other text."""
