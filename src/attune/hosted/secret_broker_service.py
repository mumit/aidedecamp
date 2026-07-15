"""Strict private HTTP adapter for mutation and fixed provider operations."""

from __future__ import annotations

import time
import logging
from typing import Any, Callable, Mapping
from uuid import UUID

from .secret_broker import SecretBroker
from .task_envelope import _google_token_verifier, _verify_claims

MAX_SECRET_REQUEST_BYTES = 70_000
LOG = logging.getLogger(__name__)


def create_app(
    broker: SecretBroker,
    *,
    expected_audience: str,
    expected_control_plane: str,
    expected_worker: str,
    token_verifier: Callable[[str, str], Mapping[str, Any]] | None = None,
):
    from flask import Flask, jsonify, request

    if not expected_audience.startswith("https://"):
        raise ValueError("expected audience must be HTTPS")
    if not expected_control_plane.endswith(".gserviceaccount.com"):
        raise ValueError("expected caller must be a service account")
    if not expected_worker.endswith(".gserviceaccount.com"):
        raise ValueError("expected caller must be a service account")
    if expected_worker == expected_control_plane:
        raise ValueError("control plane and worker identities must be distinct")
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = MAX_SECRET_REQUEST_BYTES
    verifier = token_verifier or _google_token_verifier

    def authorize(expected_service_account: str) -> bool:
        header = request.headers.get("Authorization", "")
        if len(header) > 16_384 or not header.startswith("Bearer "):
            return False
        token = header[7:]
        if not token or any(character.isspace() for character in token):
            return False
        try:
            claims = verifier(token, expected_audience)
            _verify_claims(
                claims,
                expected_audience=expected_audience,
                expected_service_account=expected_service_account,
                now=int(time.time()),
            )
        except Exception:
            return False
        return True

    def body_for(keys: set[str]):
        if not request.is_json:
            return None
        body = request.get_json(silent=True)
        return body if isinstance(body, dict) and set(body) == keys else None

    def intent_id(body):
        raw = body.get("intent_id")
        if not isinstance(raw, str):
            return None
        try:
            parsed = UUID(raw)
        except ValueError:
            return None
        return parsed if str(parsed) == raw else None

    @app.get("/healthz")
    def health():
        return jsonify({"status": "ok"})

    @app.post("/v1/credentials/install")
    def install():
        if not authorize(expected_control_plane):
            return jsonify({"error": "forbidden"}), 403
        body = body_for({"intent_id", "credential"})
        parsed = intent_id(body) if body is not None else None
        if parsed is None or not isinstance(body["credential"], dict):
            return jsonify({"error": "invalid_request"}), 400
        try:
            result = broker.install(parsed, body["credential"])
        except Exception as error:
            LOG.warning("credential install failed (%s)", type(error).__name__)
            return jsonify({"error": "broker_unavailable"}), 503
        return ("", result.status_code)

    @app.post("/v1/credentials/revoke")
    def revoke():
        if not authorize(expected_control_plane):
            return jsonify({"error": "forbidden"}), 403
        body = body_for({"intent_id"})
        parsed = intent_id(body) if body is not None else None
        if parsed is None:
            return jsonify({"error": "invalid_request"}), 400
        try:
            result = broker.revoke(parsed)
        except Exception as error:
            LOG.warning("credential revoke failed (%s)", type(error).__name__)
            return jsonify({"error": "broker_unavailable"}), 503
        return ("", result.status_code)

    @app.post("/v1/providers/google/gmail/profile")
    def google_gmail_profile():
        if not authorize(expected_worker):
            return jsonify({"error": "forbidden"}), 403
        body = body_for({"intent_id"})
        parsed = intent_id(body) if body is not None else None
        if parsed is None:
            return jsonify({"error": "invalid_request"}), 400
        try:
            result = broker.google_gmail_profile(parsed)
        except Exception as error:
            LOG.warning("credential use failed (%s)", type(error).__name__)
            return jsonify({"error": "broker_unavailable"}), 503
        if result.status_code != 200:
            # Fixed signal only: never include intent, tenant, connector,
            # credential, provider response, or exception detail.
            LOG.warning(
                "attune_secret_broker_use_anomaly status=%d",
                result.status_code,
            )
        if result.status_code == 200 and result.body is not None:
            return jsonify(result.body), 200
        return ("", result.status_code)

    return app
