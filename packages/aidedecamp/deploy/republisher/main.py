"""Thin republisher: Calendar webhook + Chat card-interaction endpoints
(docs/deployment.md §8, §12; docs/decisions.md).

A single, small, stateless Cloud Run service — the one exception to rule 5
(no inbound port on the credential-holding process). It holds no credentials,
no memory, and no Fuel iX token. Two routes, same shape: read an inbound
webhook, forward the (verified, where applicable) payload onto a Pub/Sub
topic the main aidedecamp process pulls from, return an immediate response.

- ``/calendar-webhook``: Calendar push notifications carry almost no
  payload — just headers. No verification is needed here (the notification
  is treated as untrusted-origin input regardless; the main process only
  ever uses it as a signal to re-check its sync token against the real
  Calendar API, never as a direct command). If this route is ever abused,
  the blast radius is "the main process runs an extra, harmless
  reconciliation pass."

- ``/chat-interaction``: Google Chat's approve/reject buttons need a
  synchronous HTTP response, so resuming the paused LangGraph workflow can't
  happen here — that needs the checkpointer and memory store, which this
  service must never hold. Unlike the calendar route, this ONE DOES need
  request verification: without it, anyone who finds this service's public
  URL could forge an approve/reject decision on someone else's pending
  draft. Google Chat signs its interaction calls with a bearer JWT issued by
  ``chat@system.gserviceaccount.com``; verify it before ever publishing.
  Edit's dialog-open click never touches the graph, so it's answered
  directly here, synchronously, with no Pub/Sub involved.

Deliberately NOT part of the installable ``aidedecamp`` package — this is
deployable infrastructure, like ``deploy/mem0-compose.yml``, not application
code. Has its own ``requirements.txt``/``Dockerfile`` and is deployed
independently (``gcloud run deploy --source=deploy/republisher``).

CONFIRM the exact JWT audience value expected against current Google Chat
API docs before relying on ``verify_chat_request`` in production — this
implements the documented shape (bearer JWT, issuer check, audience check
via ``google.oauth2.id_token.verify_oauth2_token``) but hasn't been
exercised against a live Chat app.
"""

from __future__ import annotations

import json
import os

from flask import Flask, jsonify, request

app = Flask(__name__)

# Mirrors ingestion/chat_interactions.py's _ACTION_APPROVE/_ACTION_REJECT and
# channels/blocks.py's ACTION_EDIT — duplicated rather than imported, since
# this service deliberately has no dependency on the aidedecamp package.
_ACTION_APPROVE = "adc_approve"
_ACTION_REJECT = "adc_reject"
_ACTION_EDIT = "adc_edit"

_CHAT_ISSUER = "chat@system.gserviceaccount.com"


# ---------------------------------------------------------------------------
# Shared publish helper
# ---------------------------------------------------------------------------


def publish(publisher, topic: str, payload: dict) -> None:
    """Publish ``payload`` and wait for confirmation before acking the
    webhook. The caller expects a fast response, but silently losing a
    notification because we returned 200 before the publish actually landed
    would be worse than the extra latency of waiting for it."""
    future = publisher.publish(topic, json.dumps(payload).encode("utf-8"))
    future.result(timeout=10)


def _default_publisher():  # pragma: no cover - requires live GCP
    from google.cloud import pubsub_v1

    return pubsub_v1.PublisherClient()


# ---------------------------------------------------------------------------
# /calendar-webhook
# ---------------------------------------------------------------------------


def decode_headers(headers: dict) -> dict:
    """Extract the ``X-Goog-*`` notification headers Google sends.

    Mirrors ``ingestion/calendar_sync.py::decode_calendar_headers``'s shape
    exactly — that's what the main process expects to parse back out of the
    Pub/Sub message this service publishes.
    """
    return {
        "channel_id": headers.get("X-Goog-Channel-ID", ""),
        "resource_id": headers.get("X-Goog-Resource-ID", ""),
        "resource_state": headers.get("X-Goog-Resource-State", ""),
        "message_number": headers.get("X-Goog-Message-Number", ""),
    }


@app.route("/calendar-webhook", methods=["POST"])
def calendar_webhook():
    payload = decode_headers(request.headers)
    publisher = app.config.get("PUBLISHER")
    if publisher is None:  # pragma: no cover - requires live GCP
        publisher = _default_publisher()
    topic = app.config.get("TOPIC") or os.environ["CALENDAR_PUBSUB_TOPIC"]
    publish(publisher, topic, payload)
    return "", 200


# ---------------------------------------------------------------------------
# /chat-interaction
# ---------------------------------------------------------------------------


def verify_chat_request(headers, *, audience: str, verify_fn=None) -> bool:
    """Verify a request actually came from Google Chat.

    Google Chat signs its interaction webhook calls with a bearer JWT
    (``Authorization: Bearer <token>``) issued by
    ``chat@system.gserviceaccount.com``. Verifying it here, before ever
    publishing to Pub/Sub, is what stops anyone who finds this service's
    public URL from forging approve/reject decisions on someone else's
    pending drafts — the async hand-off to the main process only helps if
    the thing handing off is trustworthy.
    """
    auth_header = headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return False
    token = auth_header[len("Bearer "):]

    verify = verify_fn or _default_verify
    try:
        claims = verify(token, audience)
    except Exception:  # noqa: BLE001
        return False

    return claims.get("iss") == _CHAT_ISSUER


def _default_verify(token: str, audience: str):  # pragma: no cover - requires live Google
    from google.auth.transport import requests as google_requests
    from google.oauth2 import id_token

    return id_token.verify_oauth2_token(token, google_requests.Request(), audience)


@app.route("/chat-interaction", methods=["POST"])
def chat_interaction():
    audience = app.config.get("CHAT_AUDIENCE") or os.environ.get("CHAT_APP_AUDIENCE", "")
    verify_fn = app.config.get("VERIFY_CHAT_FN")
    if not verify_chat_request(request.headers, audience=audience, verify_fn=verify_fn):
        return "", 403

    event = request.get_json(force=True, silent=True) or {}
    action = event.get("action", {})
    fn = action.get("actionMethodName", "")

    if fn == _ACTION_EDIT:
        # Opening a dialog never touches the graph — answer immediately,
        # synchronously, no Pub/Sub involved.
        return jsonify({
            "actionResponse": {
                "type": "DIALOG",
                "dialogAction": {"dialog": {"body": {}}},
            }
        })

    if fn in (_ACTION_APPROVE, _ACTION_REJECT):
        publisher = app.config.get("INTERACTION_PUBLISHER")
        if publisher is None:  # pragma: no cover - requires live GCP
            publisher = _default_publisher()
        topic = app.config.get("INTERACTION_TOPIC") or os.environ["CHAT_INTERACTION_PUBSUB_TOPIC"]
        publish(publisher, topic, event)
        return jsonify({"text": "⏳ Processing your response..."})

    return "", 200


if __name__ == "__main__":  # pragma: no cover - requires a live run
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
