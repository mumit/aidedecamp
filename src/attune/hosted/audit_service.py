"""Private HTTP adapter for the intent-only hosted audit writer."""

from __future__ import annotations

import logging
from typing import Any
from uuid import UUID

from .audit import PostgresAuditWriterRepository
from .cloud_sql import iam_connection

LOG = logging.getLogger(__name__)
MAX_REQUEST_BYTES = 1024


def create_app(writer: Any | None = None):
    from flask import Flask, jsonify, request

    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = MAX_REQUEST_BYTES
    audit_writer = writer or PostgresAuditWriterRepository(iam_connection)

    @app.get("/healthz")
    def health():
        return jsonify({"status": "ok"})

    @app.post("/v1/audit-intents/write")
    def write_intent():
        if not request.is_json:
            return jsonify({"error": "invalid_request"}), 400
        body = request.get_json(silent=True)
        if not isinstance(body, dict) or set(body) != {"audit_intent_id"}:
            return jsonify({"error": "invalid_request"}), 400
        raw_id = body["audit_intent_id"]
        if not isinstance(raw_id, str):
            return jsonify({"error": "invalid_request"}), 400
        try:
            intent_id = UUID(raw_id)
        except ValueError:
            return jsonify({"error": "invalid_request"}), 400
        if str(intent_id) != raw_id:
            return jsonify({"error": "invalid_request"}), 400
        try:
            event_id = audit_writer.write(intent_id)
        except Exception as error:
            LOG.warning("audit intent write failed (%s)", type(error).__name__)
            return jsonify({"error": "audit_unavailable"}), 503
        if event_id is None:
            return jsonify({"error": "intent_unavailable"}), 404
        return jsonify({"status": "written", "audit_event_id": str(event_id)})

    return app


app = create_app()
