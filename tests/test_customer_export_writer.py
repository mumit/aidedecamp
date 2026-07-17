"""Adversarial tests for fail-closed customer-export writer orchestration."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID

import pytest

from attune.hosted.customer_export import (
    ClaimedCustomerExport,
    CompletedCustomerExport,
    ReservedCustomerExportObject,
)
from attune.hosted.customer_export_writer import (
    CustomerExportWriter,
    ExportCleanupRequired,
    ExportExecutionFailed,
    ObjectNotFound,
    canonical_export_object_name,
)
from attune.hosted.export_crypto import ExportEnvelopeCipher

TENANT = UUID("10000000-0000-4000-8000-000000000401")
EXPORT = UUID("10000000-0000-4000-8000-000000000402")
OWNER = UUID("10000000-0000-4000-8000-000000000403")
RUN = UUID("10000000-0000-4000-8000-000000000404")
OBJECT = UUID("10000000-0000-4000-8000-000000000405")
OLD_OBJECT = UUID("10000000-0000-4000-8000-000000000406")
NOW = datetime(2026, 7, 17, tzinfo=timezone.utc)


class Wrapper:
    key_resource = "projects/test/locations/test/keyRings/test/cryptoKeys/export"

    def wrap(self, value):
        return bytes(byte ^ 0x5A for byte in value)

    def unwrap(self, value):
        return bytes(byte ^ 0x5A for byte in value)


class Claims:
    def __init__(self, claimed=True):
        self.claimed = claimed

    def claim(self, export_id, *, run_id):
        if not self.claimed:
            return None
        return ClaimedCustomerExport(
            TENANT, export_id, OWNER, "memories", NOW + timedelta(minutes=5)
        )


class Execution:
    def __init__(self):
        self.fail_code = None
        self.complete_error = None
        self.records_error = None
        self.completion = None
        self.cleanup = (OLD_OBJECT,)

    def reserve_object(self, export_id, *, run_id, proposed_object_id):
        assert proposed_object_id == OBJECT
        return ReservedCustomerExportObject(OBJECT, NOW)

    def cleanup_objects(self, export_id, *, run_id):
        return self.cleanup

    def records(self, export_id, *, run_id, expected_member):
        if self.records_error:
            raise self.records_error
        assert expected_member == "memories.jsonl"
        return (
            {
                "schema_version": 1,
                "kind": "memory",
                "data": {"id": "memory-1", "content": "customer content"},
            },
        )

    def complete(self, export_id, **metadata):
        if self.complete_error:
            raise self.complete_error
        self.completion = metadata
        return CompletedCustomerExport(EXPORT, "ready", NOW + timedelta(hours=24))

    def fail(self, export_id, *, run_id, failure_code):
        self.fail_code = failure_code


class Objects:
    def __init__(self):
        self.values = {canonical_export_object_name(OLD_OBJECT): (11, b"old")}
        self.next_generation = 12
        self.create_error = None
        self.create_then_error = False
        self.delete_error_for = set()
        self.deletions = []

    def delete(self, object_name, *, generation=None):
        self.deletions.append((object_name, generation))
        if object_name in self.delete_error_for:
            raise RuntimeError("storage unavailable")
        existing = self.values.get(object_name)
        if existing is None:
            raise ObjectNotFound()
        if generation is not None and existing[0] != generation:
            raise RuntimeError("generation mismatch")
        del self.values[object_name]

    def create(self, object_name, content):
        if self.create_error and not self.create_then_error:
            raise self.create_error
        if object_name in self.values:
            raise RuntimeError("generation precondition failed")
        self.values[object_name] = (self.next_generation, content)
        if self.create_error:
            raise self.create_error
        return self.next_generation


def _writer(execution=None, objects=None, claims=None, cipher=None):
    return CustomerExportWriter(
        claims=claims or Claims(),
        execution=execution or Execution(),
        cipher=cipher or ExportEnvelopeCipher(Wrapper()),
        objects=objects or Objects(),
        now=lambda: NOW,
        new_object_id=lambda: OBJECT,
    )


def test_writer_cleans_prior_attempt_and_completes_exact_generation():
    execution = Execution()
    objects = Objects()
    completed = _writer(execution, objects).execute(EXPORT, run_id=RUN)

    assert completed.state == "ready"
    current_name = canonical_export_object_name(OBJECT)
    assert canonical_export_object_name(OLD_OBJECT) not in objects.values
    assert objects.values[current_name][0] == 12
    assert execution.completion["object_generation"] == 12
    assert execution.completion["object_id"] == OBJECT
    assert execution.completion["ciphertext_bytes"] == (
        execution.completion["archive_bytes"] + 16
    )
    assert execution.fail_code is None


def test_unavailable_claim_performs_no_work():
    objects = Objects()
    assert _writer(objects=objects, claims=Claims(False)).execute(
        EXPORT, run_id=RUN
    ) is None
    assert objects.values
    assert objects.deletions == []


def test_projection_failure_is_terminal_only_after_objects_are_absent():
    execution = Execution()
    execution.records_error = RuntimeError("projection broke")
    objects = Objects()
    with pytest.raises(ExportExecutionFailed, match="projection_failed"):
        _writer(execution, objects).execute(EXPORT, run_id=RUN)
    assert execution.fail_code == "projection_failed"
    assert objects.values == {}


def test_archive_and_kms_failures_use_fixed_content_free_codes():
    execution = Execution()
    execution.records = lambda *args, **kwargs: ({"unexpected": "record"},)
    with pytest.raises(ExportExecutionFailed, match="archive_failed"):
        _writer(execution, Objects()).execute(EXPORT, run_id=RUN)
    assert execution.fail_code == "archive_failed"

    class BrokenCipher:
        def encrypt(self, *args, **kwargs):
            raise RuntimeError("kms request failed with sensitive diagnostics")

    execution = Execution()
    with pytest.raises(ExportExecutionFailed, match="encryption_failed"):
        _writer(execution, Objects(), cipher=BrokenCipher()).execute(
            EXPORT, run_id=RUN
        )
    assert execution.fail_code == "encryption_failed"


def test_ambiguous_upload_is_deleted_before_terminal_failure():
    execution = Execution()
    objects = Objects()
    objects.create_error = TimeoutError("ambiguous upload response")
    objects.create_then_error = True
    with pytest.raises(ExportExecutionFailed, match="upload_failed"):
        _writer(execution, objects).execute(EXPORT, run_id=RUN)
    assert execution.fail_code == "upload_failed"
    assert objects.values == {}


def test_completion_failure_deletes_only_the_uploaded_generation():
    execution = Execution()
    execution.complete_error = RuntimeError("database unavailable")
    objects = Objects()
    with pytest.raises(ExportExecutionFailed, match="completion_failed"):
        _writer(execution, objects).execute(EXPORT, run_id=RUN)
    assert execution.fail_code == "completion_failed"
    assert objects.values == {}
    assert objects.deletions[-1] == (canonical_export_object_name(OBJECT), 12)


def test_cleanup_failure_never_terminalizes_the_job():
    execution = Execution()
    objects = Objects()
    objects.delete_error_for.add(canonical_export_object_name(OLD_OBJECT))
    with pytest.raises(ExportCleanupRequired, match="could not be verified"):
        _writer(execution, objects).execute(EXPORT, run_id=RUN)
    assert execution.fail_code is None
    assert execution.completion is None


def test_post_upload_cleanup_failure_leaves_the_claim_recoverable():
    execution = Execution()
    execution.complete_error = RuntimeError("database unavailable")
    objects = Objects()
    current_name = canonical_export_object_name(OBJECT)

    original_delete = objects.delete

    def fail_current_generation(object_name, *, generation=None):
        if object_name == current_name and generation is not None:
            raise RuntimeError("delete unavailable")
        return original_delete(object_name, generation=generation)

    objects.delete = fail_current_generation
    with pytest.raises(ExportCleanupRequired, match="execution failure"):
        _writer(execution, objects).execute(EXPORT, run_id=RUN)
    assert execution.fail_code is None
    assert current_name in objects.values


def test_canonical_names_are_opaque_and_type_checked():
    assert canonical_export_object_name(OBJECT) == f"objects/{OBJECT}.bin"
    with pytest.raises(TypeError):
        canonical_export_object_name(str(OBJECT))  # type: ignore[arg-type]
