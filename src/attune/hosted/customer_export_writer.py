"""Fail-closed orchestration for the dormant hosted customer-export writer."""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from datetime import datetime, timezone
from typing import Any, Protocol
from uuid import UUID, uuid4

from .customer_export import (
    ClaimedCustomerExport,
    CompletedCustomerExport,
    PostgresCustomerExportClaims,
    ReservedCustomerExportObject,
)
from .export_archive import SCOPE_MEMBER, build_export_archive
from .export_crypto import ExportEnvelopeCipher


class ObjectNotFound(Exception):
    """The canonical export object does not exist."""


class ExportExecutionFailed(RuntimeError):
    def __init__(self, failure_code: str):
        super().__init__(f"customer export failed at stage: {failure_code}")
        self.failure_code = failure_code


class ExportCleanupRequired(RuntimeError):
    """A partial object could not be proven absent; do not terminalize the job."""


class ExportExecutionRepository(Protocol):
    def reserve_object(
        self, export_id: UUID, *, run_id: UUID, proposed_object_id: UUID
    ) -> ReservedCustomerExportObject: ...

    def records(
        self, export_id: UUID, *, run_id: UUID, expected_member: str
    ) -> Sequence[Mapping[str, Any]]: ...

    def cleanup_objects(self, export_id: UUID, *, run_id: UUID) -> Sequence[UUID]: ...

    def complete(self, export_id: UUID, **metadata: Any) -> CompletedCustomerExport: ...

    def fail(self, export_id: UUID, *, run_id: UUID, failure_code: str) -> Any: ...


class ExportObjectStore(Protocol):
    def delete(self, object_name: str, *, generation: int | None = None) -> None: ...

    def create(self, object_name: str, content: bytes) -> int: ...


class CustomerExportWriter:
    """Claim, project, encrypt, upload, and atomically complete one export."""

    def __init__(
        self,
        *,
        claims: PostgresCustomerExportClaims,
        execution: ExportExecutionRepository,
        cipher: ExportEnvelopeCipher,
        objects: ExportObjectStore,
        now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        new_object_id: Callable[[], UUID] = uuid4,
    ):
        self._claims = claims
        self._execution = execution
        self._cipher = cipher
        self._objects = objects
        self._now = now
        self._new_object_id = new_object_id

    def execute(
        self, export_id: UUID, *, run_id: UUID
    ) -> CompletedCustomerExport | None:
        if not isinstance(export_id, UUID) or not isinstance(run_id, UUID):
            raise TypeError("export_id and run_id must be UUIDs")
        claimed = self._claims.claim(export_id, run_id=run_id)
        if claimed is None:
            return None
        reservation = self._execution.reserve_object(
            export_id, run_id=run_id, proposed_object_id=self._new_object_id()
        )
        object_name = canonical_export_object_name(reservation.object_id)

        # Every attempt owns a distinct object UUID. Cleanup candidates remain
        # durable, while a late stale upload can never collide with this run.
        for cleanup_object_id in self._execution.cleanup_objects(
            export_id, run_id=run_id
        ):
            self._delete_or_require_cleanup(
                canonical_export_object_name(cleanup_object_id)
            )
        self._delete_or_require_cleanup(object_name)

        try:
            records = self._execution.records(
                export_id,
                run_id=run_id,
                expected_member=SCOPE_MEMBER[claimed.scope],
            )
        except Exception as error:
            self._fail(export_id, run_id, "projection_failed", error)
        try:
            archive = build_export_archive(
                export_id=export_id,
                scope=claimed.scope,
                requested_at=reservation.requested_at,
                generated_at=self._now(),
                records=records,
            )
        except Exception as error:
            self._fail(export_id, run_id, "archive_failed", error)
        try:
            encrypted = self._cipher.encrypt(
                archive,
                tenant_id=claimed.tenant_id,
                export_id=export_id,
                scope=claimed.scope,
                object_id=reservation.object_id,
            )
        except Exception as error:
            self._fail(export_id, run_id, "encryption_failed", error)

        try:
            generation = self._objects.create(object_name, encrypted.ciphertext)
            if not isinstance(generation, int) or generation <= 0:
                raise RuntimeError("object store returned an invalid generation")
        except Exception as error:
            self._delete_or_require_cleanup(object_name, cause=error)
            self._fail(export_id, run_id, "upload_failed", error)

        try:
            return self._execution.complete(
                export_id,
                run_id=run_id,
                object_id=reservation.object_id,
                object_generation=generation,
                wrapped_dek=encrypted.wrapped_dek,
                nonce=encrypted.nonce,
                key_resource=encrypted.key_resource,
                archive_sha256=encrypted.plaintext_sha256,
                ciphertext_sha256=encrypted.ciphertext_sha256,
                archive_bytes=encrypted.plaintext_bytes,
                ciphertext_bytes=len(encrypted.ciphertext),
                encryption_format=encrypted.format_version,
            )
        except Exception as error:
            self._delete_or_require_cleanup(
                object_name, generation=generation, cause=error
            )
            self._fail(export_id, run_id, "completion_failed", error)
        raise AssertionError("unreachable")

    def _fail(
        self, export_id: UUID, run_id: UUID, failure_code: str, cause: Exception
    ) -> None:
        self._execution.fail(
            export_id, run_id=run_id, failure_code=failure_code
        )
        raise ExportExecutionFailed(failure_code) from cause

    def _delete_or_require_cleanup(
        self,
        object_name: str,
        *,
        generation: int | None = None,
        cause: Exception | None = None,
    ) -> None:
        try:
            self._objects.delete(object_name, generation=generation)
        except ObjectNotFound:
            return
        except Exception as cleanup_error:
            message = "customer export object cleanup could not be verified"
            if cause is not None:
                message += " after an execution failure"
            raise ExportCleanupRequired(message) from cleanup_error


def canonical_export_object_name(object_id: UUID) -> str:
    if not isinstance(object_id, UUID):
        raise TypeError("object_id must be a UUID")
    return f"objects/{object_id}.bin"
