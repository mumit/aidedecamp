"""Interaction surfaces (design doc 3.1). One brain, many doors.

Slack (Socket Mode, approvals via buttons) and Google Chat (Cards v2,
CARD_CLICKED interaction events via thin republisher). Browser and voice later.
All are thin surfaces over the single orchestrator and memory store — they
render and collect, they do not decide.
"""

from .blocks import (
    ACTION_APPROVE,
    ACTION_EDIT,
    ACTION_REJECT,
    approval_blocks,
    brief_blocks,
)
from .slack import SlackChannel
from .gchat import GoogleChatChannel, make_chat_send_fn
from .gchat_cards import approval_card, brief_card

__all__ = [
    "SlackChannel",
    "GoogleChatChannel",
    "make_chat_send_fn",
    "brief_blocks",
    "approval_blocks",
    "brief_card",
    "approval_card",
    "ACTION_APPROVE",
    "ACTION_EDIT",
    "ACTION_REJECT",
]
