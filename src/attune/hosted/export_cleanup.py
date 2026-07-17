"""Bounded delete-only cleanup for abandoned customer-export attempts."""

from __future__ import annotations

import json
import os
from contextlib import closing
from dataclasses import dataclass
from typing import Any, Protocol
from uuid import UUID, uuid4

from .cloud_sql import iam_connection
from .customer_export_writer import ObjectNotFound, canonical_export_object_name
from .export_storage import validate_export_object_name
from .repositories import ConnectionFactory


@dataclass(frozen=True)
class ExportCleanupCandidate:
    tenant_id: UUID
    export_id: UUID
    attempt_run_id: UUID
    object_id: UUID


class DeleteOnlyExportObjects(Protocol):
    def delete(self, object_name: str) -> None: ...


class PostgresExportCleanupRepository:
    def __init__(self, connection_factory: ConnectionFactory):
        self._connect = connection_factory

    def claim(self, *, cleanup_run_id: UUID, batch_size: int) -> tuple[ExportCleanupCandidate, ...]:
        with closing(self._connect()) as connection:
            with closing(connection.cursor()) as cursor:
                cursor.execute(
                    "SELECT * FROM attune.claim_customer_export_attempt_cleanups(%s,%s)",
                    (cleanup_run_id, batch_size),
                )
                rows = cursor.fetchall()
            connection.commit()
        return tuple(ExportCleanupCandidate(*row) for row in rows)

    def complete(self, candidate: ExportCleanupCandidate, *, cleanup_run_id: UUID) -> bool:
        with closing(self._connect()) as connection:
            with closing(connection.cursor()) as cursor:
                cursor.execute(
                    "SELECT attune.complete_customer_export_attempt_cleanup(%s,%s,%s)",
                    (candidate.export_id, candidate.attempt_run_id, cleanup_run_id),
                )
                row = cursor.fetchone()
            connection.commit()
        if row is None or not isinstance(row[0], bool):
            raise RuntimeError("export cleanup completion returned an invalid result")
        return row[0]


def run_export_cleanup(
    repository: PostgresExportCleanupRepository,
    objects: DeleteOnlyExportObjects,
    *,
    batch_size: int = 50,
    max_batches: int = 4,
) -> dict[str, int | bool]:
    if not isinstance(batch_size, int) or isinstance(batch_size, bool) or not 1 <= batch_size <= 100:
        raise ValueError("batch_size must be an integer between 1 and 100")
    if not isinstance(max_batches, int) or isinstance(max_batches, bool) or not 1 <= max_batches <= 10:
        raise ValueError("max_batches must be an integer between 1 and 10")
    deleted = 0
    batches = 0
    backlog_possible = False
    for batch_index in range(max_batches):
        cleanup_run_id = uuid4()
        candidates = repository.claim(
            cleanup_run_id=cleanup_run_id, batch_size=batch_size
        )
        batches = batch_index + 1
        for candidate in candidates:
            try:
                objects.delete(canonical_export_object_name(candidate.object_id))
            except ObjectNotFound:
                pass
            repository.complete(candidate, cleanup_run_id=cleanup_run_id)
            deleted += 1
        if len(candidates) < batch_size:
            break
    else:
        backlog_possible = len(candidates) == batch_size
    return {
        "objects_deleted": deleted,
        "batches": batches,
        "backlog_possible": backlog_possible,
    }


class GoogleDeleteOnlyExportObjects:
    def __init__(self, bucket_name: str, *, client: Any | None = None):
        if not isinstance(bucket_name, str) or not 3 <= len(bucket_name) <= 63:
            raise ValueError("invalid customer export bucket name")
        if client is None:
            from google.cloud import storage

            client = storage.Client()
        self._bucket = client.bucket(bucket_name)

    def delete(self, object_name: str) -> None:
        from google.api_core.exceptions import NotFound

        validate_export_object_name(object_name)
        try:
            self._bucket.blob(object_name).delete()
        except NotFound as error:
            raise ObjectNotFound() from error


def main() -> None:
    batch_size = int(os.environ.get("ATTUNE_EXPORT_CLEANUP_BATCH_SIZE", "50"))
    max_batches = int(os.environ.get("ATTUNE_EXPORT_CLEANUP_MAX_BATCHES", "4"))
    repository = PostgresExportCleanupRepository(iam_connection)
    objects = GoogleDeleteOnlyExportObjects(os.environ["ATTUNE_EXPORT_BUCKET"])
    result = run_export_cleanup(
        repository, objects, batch_size=batch_size, max_batches=max_batches
    )
    print(json.dumps({
        "severity": "WARNING" if result["backlog_possible"] else "INFO",
        "message": "Attune export cleanup completed",
        "event": "attune_export_cleanup",
        **result,
    }, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
