"""Strict private HTTP boundary for opaque dispatch intents."""

from __future__ import annotations

import logging
import time
from typing import Any, Callable, Mapping
from uuid import UUID

from .dispatch_broker import DispatchBroker
from .task_envelope import _google_token_verifier, _verify_claims

LOG = logging.getLogger(__name__)
MAX_REQUEST_BYTES = 1024
PRODUCER_KINDS = frozenset({"control_plane", "ingress", "worker"})


def create_app(
    broker: DispatchBroker,
    *,
    expected_audience: str,
    expected_callers: Mapping[str, str],
    token_verifier: Callable[[str, str], Mapping[str, Any]] | None = None,
):
    from flask import Flask, jsonify, request

    if not expected_audience.startswith("https://"):
        raise ValueError("expected audience must be HTTPS")
    if set(expected_callers) != PRODUCER_KINDS:
        raise ValueError("every dispatch producer identity must be configured")
    if len(set(expected_callers.values())) != len(PRODUCER_KINDS) or any(
        not email.endswith(".gserviceaccount.com")
        for email in expected_callers.values()
    ):
        raise ValueError("dispatch producer identities must be distinct service accounts")
    caller_kinds = {email: kind for kind, email in expected_callers.items()}
    verifier = token_verifier or _google_token_verifier
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = MAX_REQUEST_BYTES

    def authorize() -> str | None:
        header = request.headers.get("Authorization", "")
        if len(header) > 16_384 or not header.startswith("Bearer "):
            return None
        token = header[7:]
        if not token or any(character.isspace() for character in token):
            return None
        try:
            claims = verifier(token, expected_audience)
            email = claims.get("email")
            producer_kind = caller_kinds.get(email)
            if producer_kind is None:
                return None
            _verify_claims(
                claims,
                expected_audience=expected_audience,
                expected_service_account=email,
                now=int(time.time()),
            )
            return producer_kind
        except Exception:
            return None

    @app.get("/healthz")
    def health():
        return jsonify({"status": "ok"})

    @app.post("/v1/dispatch-intents/dispatch")
    def dispatch():
        producer_kind = authorize()
        if producer_kind is None:
            return jsonify({"error": "forbidden"}), 403
        if not request.is_json:
            return jsonify({"error": "invalid_request"}), 400
        body = request.get_json(silent=True)
        if not isinstance(body, dict) or set(body) != {"intent_id"}:
            return jsonify({"error": "invalid_request"}), 400
        raw_id = body["intent_id"]
        if not isinstance(raw_id, str):
            return jsonify({"error": "invalid_request"}), 400
        try:
            intent_id = UUID(raw_id)
        except ValueError:
            return jsonify({"error": "invalid_request"}), 400
        if str(intent_id) != raw_id:
            return jsonify({"error": "invalid_request"}), 400
        try:
            result = broker.dispatch(intent_id, producer_kind=producer_kind)
        except Exception as error:
            LOG.warning("dispatch failed (%s)", type(error).__name__)
            return jsonify({"error": "broker_unavailable"}), 503
        return ("", result.status_code)

    return app
