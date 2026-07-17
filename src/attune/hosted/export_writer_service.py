"""Authenticated Cloud Tasks boundary for the customer-export writer."""

from __future__ import annotations

import logging
from contextlib import closing
from dataclasses import dataclass
from typing import Protocol
from uuid import UUID, uuid4

from .customer_export_writer import (
    CustomerExportWriter,
    ExportCleanupRequired,
    ExportExecutionFailed,
)
from .repositories import ConnectionFactory
from .task_envelope import TokenVerifier, verify_task_envelope

LOG = logging.getLogger(__name__)
PURPOSE = "customer.export.generate"
MAX_REQUEST_BYTES = 4096


@dataclass(frozen=True)
class ExportTaskClaim:
    export_id: UUID
    state: str


class ExportTaskAuthority(Protocol):
    def claim(
        self, *, tenant_id: UUID, job_id: UUID, delivery_id: UUID
    ) -> ExportTaskClaim | None: ...

    def finish(self, *, tenant_id: UUID, job_id: UUID, delivery_id: UUID) -> str: ...


class PostgresExportTaskAuthority:
    def __init__(self, connection_factory: ConnectionFactory):
        self._connect = connection_factory

    def claim(
        self, *, tenant_id: UUID, job_id: UUID, delivery_id: UUID
    ) -> ExportTaskClaim | None:
        _uuid_values(tenant_id, job_id, delivery_id)
        with closing(self._connect()) as connection:
            with closing(connection.cursor()) as cursor:
                cursor.execute(
                    "SELECT * FROM attune.claim_customer_export_task(%s,%s,%s)",
                    (tenant_id, job_id, delivery_id),
                )
                row = cursor.fetchone()
            connection.commit()
        return ExportTaskClaim(*row) if row is not None else None

    def finish(self, *, tenant_id: UUID, job_id: UUID, delivery_id: UUID) -> str:
        _uuid_values(tenant_id, job_id, delivery_id)
        with closing(self._connect()) as connection:
            with closing(connection.cursor()) as cursor:
                cursor.execute(
                    "SELECT attune.finish_customer_export_task(%s,%s,%s)",
                    (tenant_id, job_id, delivery_id),
                )
                row = cursor.fetchone()
            connection.commit()
        if row is None or row[0] not in {"succeeded", "failed"}:
            raise RuntimeError("export task completion returned an invalid state")
        return row[0]


class ExportTaskDispatcher:
    def __init__(
        self,
        *,
        authority: ExportTaskAuthority,
        writer: CustomerExportWriter,
        expected_audience: str,
        expected_service_account: str,
        token_verifier: TokenVerifier | None = None,
    ):
        self._authority = authority
        self._writer = writer
        self._audience = expected_audience
        self._service_account = expected_service_account
        self._token_verifier = token_verifier

    def dispatch(self, *, authorization: str, raw_body: bytes) -> int:
        try:
            envelope = verify_task_envelope(
                authorization=authorization,
                raw_body=raw_body,
                expected_audience=self._audience,
                expected_service_account=self._service_account,
                allowed_purposes={PURPOSE},
                token_verifier=self._token_verifier,
            )
        except PermissionError:
            return 403
        except ValueError:
            return 400

        try:
            claim = self._authority.claim(
                tenant_id=envelope.tenant.tenant_id,
                job_id=envelope.job_id,
                delivery_id=envelope.delivery_id,
            )
        except Exception as error:
            LOG.warning("export task claim failed (%s)", type(error).__name__)
            return 503
        if claim is None:
            return 403
        if claim.state in {"succeeded", "failed"}:
            return 204
        if claim.state == "busy":
            return 503
        if claim.state != "claimed":
            return 503

        try:
            self._writer.execute(
                claim.export_id,
                run_id=uuid4(),
                expected_tenant_id=envelope.tenant.tenant_id,
            )
        except ExportExecutionFailed as error:
            LOG.warning(
                "export execution reached a terminal failure (%s)",
                error.failure_code,
            )
        except ExportCleanupRequired as error:
            LOG.error("export cleanup required (%s)", type(error).__name__)
            return 503
        except Exception as error:
            LOG.warning("export execution failed (%s)", type(error).__name__)
            return 503

        try:
            self._authority.finish(
                tenant_id=envelope.tenant.tenant_id,
                job_id=envelope.job_id,
                delivery_id=envelope.delivery_id,
            )
        except Exception as error:
            LOG.warning("export task completion failed (%s)", type(error).__name__)
            return 503
        return 204


def create_app(dispatcher: ExportTaskDispatcher):
    from flask import Flask, jsonify, request

    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = MAX_REQUEST_BYTES

    @app.get("/healthz")
    def health():
        return jsonify({"status": "ok"})

    @app.post("/v1/tasks/customer-export")
    def dispatch():
        return (
            "",
            dispatcher.dispatch(
                authorization=request.headers.get("Authorization", ""),
                raw_body=request.get_data(cache=False),
            ),
        )

    return app


def _uuid_values(*values: UUID) -> None:
    if not all(isinstance(value, UUID) for value in values):
        raise TypeError("export task identifiers must be UUIDs")
