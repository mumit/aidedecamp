"""Tests for ingestion/chat_interactions.py — no live services.

Also enforces that the duplicated action-name strings stay in sync with
channels/blocks.py, the same technique test_gchat.py already uses to keep
Slack/Chat in sync.
"""

from __future__ import annotations

from aidedecamp.ingestion.chat_interactions import ChatInteraction, decode_chat_interaction


def _click(fn: str, thread_id: str | None = "t-1") -> dict:
    params = [{"key": "thread_id", "value": thread_id}] if thread_id else []
    return {
        "type": "CARD_CLICKED",
        "action": {"actionMethodName": fn, "parameters": params},
    }


# ---------------------------------------------------------------------------
# decode_chat_interaction
# ---------------------------------------------------------------------------


def test_approve_decodes_to_approved():
    result = decode_chat_interaction(_click("adc_approve", "t-42"))
    assert isinstance(result, ChatInteraction)
    assert result.thread_id == "t-42"
    assert result.decision == "approved"


def test_reject_decodes_to_rejected():
    result = decode_chat_interaction(_click("adc_reject", "t-9"))
    assert result.thread_id == "t-9"
    assert result.decision == "rejected"


def test_edit_returns_none():
    """Edit's initial click never touches the graph — the republisher
    handles it synchronously, so it's deliberately outside this decode."""
    result = decode_chat_interaction(_click("adc_edit", "t-1"))
    assert result is None


def test_unknown_action_returns_none():
    result = decode_chat_interaction(_click("unknown_fn"))
    assert result is None


def test_non_card_clicked_returns_none():
    result = decode_chat_interaction({"type": "MESSAGE"})
    assert result is None


def test_missing_thread_id_returns_none():
    result = decode_chat_interaction(_click("adc_approve", thread_id=None))
    assert result is None


def test_missing_action_returns_none():
    result = decode_chat_interaction({"type": "CARD_CLICKED"})
    assert result is None


# ---------------------------------------------------------------------------
# Action name parity with channels/blocks.py (duplicated, not imported — see
# module docstring for why)
# ---------------------------------------------------------------------------


def test_action_names_match_blocks_py():
    from aidedecamp.channels.blocks import ACTION_APPROVE, ACTION_REJECT
    from aidedecamp.ingestion.chat_interactions import _ACTION_APPROVE, _ACTION_REJECT

    assert _ACTION_APPROVE == ACTION_APPROVE
    assert _ACTION_REJECT == ACTION_REJECT
