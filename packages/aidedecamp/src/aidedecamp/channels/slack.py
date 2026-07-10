"""The Slack channel (design doc 3.1, 4.6) — a thin door onto the orchestrator.

Design stance: the channel owns no assistant logic. It renders briefs and
approval cards, and translates button clicks into ``Command(resume=...)`` on the
paused LangGraph workflow. Everything that decides, drafts, or learns lives in
the orchestrator; Slack is one of several interchangeable surfaces over the same
brain (the "one brain, many doors" principle).

Transport: Socket Mode (outbound WebSocket). This is a deliberate security
choice — the process holding credentials and memory has no inbound port, which
is the concrete architectural answer to the OpenClaw class of attacks (design
8.1). ngrok / public request URLs are not used.

slack_bolt is a lazy optional import so the package loads without it; the graph,
connector, and client are injected so the wiring is testable without a live
Slack connection.
"""

from __future__ import annotations

from typing import Any, Callable

from .blocks import (
    ACTION_APPROVE,
    ACTION_EDIT,
    ACTION_REJECT,
    approval_blocks,
    brief_blocks,
)


class SlackChannel:
    """Wires a Bolt app to the orchestrator. Construct, then ``start()``.

    Args:
        graph: a compiled draft-and-approve graph (has .invoke).
        resume_fn: callable(thread_id, decision, text) -> resumes the graph.
            Injected so tests don't need a real compiled graph; defaults to a
            Command(resume=...) invoke against ``graph``.
        app: a pre-built Bolt App (tests inject a fake); if None, one is created
            from env tokens on first use.
    """

    def __init__(
        self,
        *,
        graph: Any = None,
        resume_fn: Callable[[str, str, str | None], Any] | None = None,
        app: Any = None,
    ):
        self._graph = graph
        self._app = app
        self._resume = resume_fn or self._default_resume
        if app is not None:
            self._register(app)

    # --- public surface ---------------------------------------------------

    def post_brief(self, say: Callable[..., Any], brief: Any) -> None:
        """Post a morning brief into a channel/thread via a Bolt ``say``."""
        say(
            blocks=brief_blocks(
                summary=brief.summary,
                unread_count=brief.unread_count,
                event_count=brief.event_count,
            ),
            text="Your morning brief",
        )

    def post_approval(self, say: Callable[..., Any], *, thread_id: str, domain: str,
                      proposed_draft: str, rationale: list[str] | None = None) -> None:
        """Post a draft-approval card for a paused workflow."""
        say(
            blocks=approval_blocks(
                thread_id=thread_id,
                domain=domain,
                proposed_draft=proposed_draft,
                rationale=rationale,
            ),
            text="A draft needs your approval",
        )

    def start(self) -> None:  # pragma: no cover - requires live Slack
        """Run the Socket Mode handler (blocks)."""
        app = self._ensure_app()
        from slack_bolt.adapter.socket_mode import SocketModeHandler
        import os

        SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"]).start()

    # --- internals --------------------------------------------------------

    def _default_resume(self, thread_id: str, decision: str, text: str | None):
        from langgraph.types import Command

        cfg = {"configurable": {"thread_id": thread_id}}
        payload: dict[str, Any] = {"decision": decision}
        if text is not None:
            payload["text"] = text
        return self._graph.invoke(Command(resume=payload), cfg)

    def _ensure_app(self):  # pragma: no cover - requires slack_bolt + env
        if self._app is None:
            import os
            from slack_bolt import App

            self._app = App(token=os.environ["SLACK_BOT_TOKEN"])
            self._register(self._app)
        return self._app

    def _register(self, app: Any) -> None:
        """Attach the three approval-button handlers to a Bolt app.

        Each handler acks immediately (Slack's 3s rule), extracts the workflow
        thread_id from the button value, and resumes the graph with the matching
        decision. Edit opens a modal in the real app; here it resumes with an
        'edited' decision whose text the modal supplies."""

        @app.action(ACTION_APPROVE)
        def _approve(ack, body, respond):  # noqa: ANN001
            ack()
            thread_id = body["actions"][0]["value"]
            self._resume(thread_id, "approved", None)
            respond(text="✅ Approved — sending.", replace_original=True)

        @app.action(ACTION_REJECT)
        def _reject(ack, body, respond):  # noqa: ANN001
            ack()
            thread_id = body["actions"][0]["value"]
            self._resume(thread_id, "rejected", None)
            respond(text="🗑️ Rejected — nothing sent.", replace_original=True)

        @app.action(ACTION_EDIT)
        def _edit(ack, body, client):  # noqa: ANN001 # pragma: no cover - modal UI
            ack()
            # In the full app this opens a modal prefilled with the draft; on
            # submit it calls self._resume(thread_id, "edited", edited_text).
            # The modal round-trip is UI wiring deferred to implementation.
            pass
