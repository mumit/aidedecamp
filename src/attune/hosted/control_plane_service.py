"""Locked public shell for the hosted control-plane edge."""

from __future__ import annotations

import re

HOSTNAME = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)


def create_app(expected_host: str):
    from flask import Flask, jsonify

    if not isinstance(expected_host, str) or not HOSTNAME.fullmatch(expected_host):
        raise ValueError("expected control-plane host must be a DNS hostname")
    app = Flask(__name__)
    app.config.update(
        MAX_CONTENT_LENGTH=1024,
        TRUSTED_HOSTS=[expected_host],
    )

    @app.after_request
    def security_headers(response):
        response.headers["Cache-Control"] = "no-store"
        response.headers["Content-Security-Policy"] = (
            "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; "
            "form-action 'none'"
        )
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Strict-Transport-Security"] = "max-age=31536000"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        return response

    @app.get("/healthz")
    def health():
        return jsonify({"status": "ok", "mode": "not_activated"})

    @app.get("/")
    def unavailable():
        return jsonify({"status": "not_activated"}), 503

    @app.errorhandler(404)
    def not_found(_error):
        return jsonify({"error": "not_found"}), 404

    @app.errorhandler(405)
    def method_not_allowed(_error):
        return jsonify({"error": "method_not_allowed"}), 405

    return app
