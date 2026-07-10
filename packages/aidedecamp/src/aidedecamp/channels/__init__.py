"""Interaction surfaces (design doc 3.1). One brain, many doors.

Slack first (Socket Mode, approvals via buttons), Google Chat next (cards),
browser and voice later. All are thin surfaces over the single orchestrator and
memory store — they render and collect, they do not decide.
"""

from .blocks import (
    ACTION_APPROVE,
    ACTION_EDIT,
    ACTION_REJECT,
    approval_blocks,
    brief_blocks,
)
from .slack import SlackChannel

__all__ = [
    "SlackChannel",
    "brief_blocks",
    "approval_blocks",
    "ACTION_APPROVE",
    "ACTION_EDIT",
    "ACTION_REJECT",
]
