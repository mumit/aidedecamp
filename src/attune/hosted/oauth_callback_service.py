"""Credential-free public scrubber for dormant hosted OAuth callbacks."""

from __future__ import annotations

import re

HOSTNAME = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)
MAX_CALLBACK_QUERY_BYTES = 4096


def create_app(expected_host: str):
    """Create an inert callback endpoint that never interprets OAuth material."""
    from flask import Flask, Response, abort, jsonify, redirect, request

    if not isinstance(expected_host, str) or not HOSTNAME.fullmatch(expected_host):
        raise ValueError("expected OAuth callback host must be a DNS hostname")
    app = Flask(__name__)
    app.config.update(
        MAX_CONTENT_LENGTH=1024,
        TRUSTED_HOSTS=[expected_host],
    )

    @app.after_request
    def security_headers(response: Response):
        response.headers["Cache-Control"] = "no-store"
        response.headers["Content-Security-Policy"] = (
            "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; "
            "form-action 'none'"
        )
        response.headers["Cross-Origin-Opener-Policy"] = "same-origin"
        response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
        response.headers["Permissions-Policy"] = (
            "camera=(), microphone=(), geolocation=(), payment=()"
        )
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Strict-Transport-Security"] = "max-age=31536000"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        return response

    @app.get("/healthz")
    def health():
        return jsonify({"status": "ok", "mode": "oauth_not_activated"})

    @app.get("/oauth/google/callback")
    def google_callback():
        # Do not parse, copy, persist, exchange, or log query parameters while
        # OAuth is dormant. The redirect immediately removes them from the URL.
        if len(request.query_string) > MAX_CALLBACK_QUERY_BYTES:
            abort(400)
        return redirect("/", code=303)

    @app.errorhandler(400)
    def bad_request(_error):
        return jsonify({"error": "invalid_callback"}), 400

    @app.errorhandler(404)
    def not_found(_error):
        return jsonify({"error": "not_found"}), 404

    @app.errorhandler(405)
    def method_not_allowed(_error):
        return jsonify({"error": "method_not_allowed"}), 405

    return app
