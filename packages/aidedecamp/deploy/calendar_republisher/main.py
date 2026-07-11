"""Calendar webhook republisher (docs/deployment.md §8).

A thin, stateless Cloud Run service — the one exception to rule 5 (no inbound
port on the credential-holding process). This service holds no credentials,
no memory, and no Fuel iX token; it only reads a Calendar push notification's
headers and republishes them onto the Pub/Sub topic the main aidedecamp
process pulls from (``ingestion/calendar_sync.py``'s
``process_calendar_notification``). If this service is ever compromised, the
blast radius is "can publish a bogus headers-only message onto one topic" —
which the main process just safely re-reconciles from, since it never
trusted the payload for anything beyond "go check your sync token." It can't
reach credentials, memory, or the Fuel iX token, because it never has them.

Deliberately NOT part of the installable ``aidedecamp`` package (see
docs/deployment.md §8) — this is deployable infrastructure, like
``deploy/mem0-compose.yml``, not application code. Has its own
``requirements.txt``/``Dockerfile`` and is deployed independently
(``gcloud run deploy --source=./calendar_republisher``).
"""

from __future__ import annotations

import json
import os

from flask import Flask, request

app = Flask(__name__)


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


def publish(publisher, topic: str, payload: dict) -> None:
    """Publish ``payload`` and wait for confirmation before acking the
    webhook. Google expects a fast response, but silently losing a
    notification because we returned 200 before the publish actually landed
    would be worse than the extra latency of waiting for it."""
    future = publisher.publish(topic, json.dumps(payload).encode("utf-8"))
    future.result(timeout=10)


def _default_publisher():  # pragma: no cover - requires live GCP
    from google.cloud import pubsub_v1

    return pubsub_v1.PublisherClient()


@app.route("/calendar-webhook", methods=["POST"])
def calendar_webhook():
    payload = decode_headers(request.headers)
    publisher = app.config.get("PUBLISHER")
    if publisher is None:  # pragma: no cover - requires live GCP
        publisher = _default_publisher()
    topic = app.config.get("TOPIC") or os.environ["CALENDAR_PUBSUB_TOPIC"]
    publish(publisher, topic, payload)
    return "", 200


if __name__ == "__main__":  # pragma: no cover - requires a live run
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
