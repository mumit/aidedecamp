"""Slack Block Kit builders (design doc 3.1).

Pure functions that turn domain objects into Slack block payloads. Kept separate
from the app wiring so they're testable without a Slack connection and reusable
across Slack and (later) Google Chat cards. No side effects, no I/O.

The approval card is the visible form of the rung-2 loop: it shows the proposed
draft and offers Approve / Edit / Reject, each carrying the graph's thread_id so
the click can be routed back to resume the exact paused workflow.
"""

from __future__ import annotations

from typing import Any

# action_ids the app listens for. Centralized so the app wiring and the card
# can't drift apart.
ACTION_APPROVE = "adc_approve"
ACTION_EDIT = "adc_edit"
ACTION_REJECT = "adc_reject"


def brief_blocks(*, summary: str, unread_count: int, event_count: int) -> list[dict[str, Any]]:
    """Render the morning brief as Slack blocks."""
    return [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": "Morning brief", "emoji": True},
        },
        {
            "type": "context",
            "elements": [
                {
                    "type": "mrkdwn",
                    "text": f"*{unread_count}* unread · *{event_count}* events today",
                }
            ],
        },
        {"type": "section", "text": {"type": "mrkdwn", "text": summary}},
    ]


def approval_blocks(
    *,
    thread_id: str,
    domain: str,
    proposed_draft: str,
    rationale: list[str] | None = None,
) -> list[dict[str, Any]]:
    """Render a draft-approval card.

    ``thread_id`` is the LangGraph thread id of the paused workflow; it's carried
    in each button's ``value`` so the action handler can resume the right graph.
    """
    why = ""
    if rationale:
        why = "\n".join(f"• {r}" for r in rationale[:3])

    blocks: list[dict[str, Any]] = [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*Draft reply* ({domain}) — approve before it goes out:",
            },
        },
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f">>> {proposed_draft}"},
        },
    ]
    if why:
        blocks.append(
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": f"Based on: {why}"}],
            }
        )
    blocks.append(
        {
            "type": "actions",
            "block_id": f"adc_approval:{thread_id}",
            "elements": [
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "Approve"},
                    "style": "primary",
                    "action_id": ACTION_APPROVE,
                    "value": thread_id,
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "Edit"},
                    "action_id": ACTION_EDIT,
                    "value": thread_id,
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "Reject"},
                    "style": "danger",
                    "action_id": ACTION_REJECT,
                    "value": thread_id,
                },
            ],
        }
    )
    return blocks
