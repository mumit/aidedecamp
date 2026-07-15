"""Private authenticated HTTP adapter for one-time OAuth exchange."""

from __future__ import annotations

import time
from typing import Any, Callable, Mapping

from .oauth_exchange import OAuthExchange
from .task_envelope import _google_token_verifier, _verify_claims

MAX_OAUTH_EXCHANGE_BYTES = 16_384


def create_app(
    exchange: OAuthExchange,
    *,
    expected_audience: str,
    expected_callback: str,
    token_verifier: Callable[[str, str], Mapping[str, Any]] | None = None,
):
    from flask import Flask, jsonify, request

    if not expected_audience.startswith("https://"):
        raise ValueError("expected audience must be HTTPS")
    if not expected_callback.endswith(".gserviceaccount.com"):
        raise ValueError("expected callback must be a service account")
    verifier = token_verifier or _google_token_verifier
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = MAX_OAUTH_EXCHANGE_BYTES

    def authorized() -> bool:
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
                expected_service_account=expected_callback,
                now=int(time.time()),
            )
        except Exception:
            return False
        return True

    @app.get("/healthz")
    def health():
        return jsonify({"status": "ok"})

    @app.post("/v1/oauth/google/exchange")
    def google_exchange():
        if not authorized():
            return jsonify({"error": "forbidden"}), 403
        body = request.get_json(silent=True) if request.is_json else None
        if not isinstance(body, dict) or set(body) != {"code", "state", "binding"}:
            return jsonify({"error": "invalid_request"}), 400
        if not all(isinstance(body[key], str) for key in body):
            return jsonify({"error": "invalid_request"}), 400
        result = exchange.exchange(
            authorization_code=body["code"],
            state=body["state"],
            binding=body["binding"],
        )
        return ("", result.status_code)

    return app
