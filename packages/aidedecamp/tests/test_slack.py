"""Slack channel tests. A fake Bolt app captures registered handlers so we can
fire button actions and assert they resume the graph — no live Slack, no
slack_bolt needed.
"""

from __future__ import annotations

from aidedecamp.channels import (
    ACTION_APPROVE,
    ACTION_EDIT,
    ACTION_REJECT,
    SlackChannel,
    approval_blocks,
    brief_blocks,
)


class FakeApp:
    """Captures @app.action handlers by action_id."""

    def __init__(self):
        self.handlers = {}

    def action(self, action_id):
        def deco(fn):
            self.handlers[action_id] = fn
            return fn
        return deco


def _say_recorder():
    calls = []

    def say(**kwargs):
        calls.append(kwargs)

    return say, calls


# --- block builders ------------------------------------------------------

def test_brief_blocks_shape():
    blocks = brief_blocks(summary="all quiet", unread_count=3, event_count=2)
    assert blocks[0]["type"] == "header"
    assert "3" in blocks[1]["elements"][0]["text"]
    assert "all quiet" in blocks[-1]["text"]["text"]


def test_approval_blocks_carry_thread_id():
    blocks = approval_blocks(
        thread_id="t-42", domain="mail", proposed_draft="Hi there",
        rationale=["prefers short replies"],
    )
    actions = [b for b in blocks if b["type"] == "actions"][0]
    # every button carries the workflow thread_id so the click can resume it
    assert all(el["value"] == "t-42" for el in actions["elements"])
    ids = {el["action_id"] for el in actions["elements"]}
    assert ids == {ACTION_APPROVE, ACTION_EDIT, ACTION_REJECT}


# --- button -> resume routing -------------------------------------------

def _make_channel():
    resumes = []
    ch = SlackChannel(resume_fn=lambda tid, decision, text: resumes.append(
        (tid, decision, text)), app=FakeApp())
    return ch, resumes


def test_approve_button_resumes_graph_approved():
    ch, resumes = _make_channel()
    ack_called = []
    body = {"actions": [{"value": "t-7"}]}
    ch._app.handlers[ACTION_APPROVE](
        ack=lambda: ack_called.append(True), body=body, respond=lambda **k: None
    )
    assert ack_called == [True]           # acked within Slack's 3s window
    assert resumes == [("t-7", "approved", None)]


def test_reject_button_resumes_graph_rejected():
    ch, resumes = _make_channel()
    body = {"actions": [{"value": "t-9"}]}
    ch._app.handlers[ACTION_REJECT](
        ack=lambda: None, body=body, respond=lambda **k: None
    )
    assert resumes == [("t-9", "rejected", None)]


def test_post_brief_uses_say():
    ch = SlackChannel(app=FakeApp())
    say, calls = _say_recorder()

    class B:
        summary = "2 unread"
        unread_count = 2
        event_count = 0

    ch.post_brief(say, B())
    assert calls and calls[0]["blocks"][0]["type"] == "header"


def test_post_approval_uses_say():
    ch = SlackChannel(app=FakeApp())
    say, calls = _say_recorder()
    ch.post_approval(say, thread_id="t1", domain="mail", proposed_draft="hey")
    assert calls
    actions = [b for b in calls[0]["blocks"] if b["type"] == "actions"][0]
    assert actions["elements"][0]["value"] == "t1"
