"""Adversarial tests for deterministic customer-export archive construction."""

from __future__ import annotations

import hashlib
import io
import json
import zipfile
from datetime import datetime, timezone
from uuid import UUID

import pytest

from attune.hosted import export_archive


EXPORT_ID = UUID("10000000-0000-4000-8000-000000000101")
NOW = datetime(2026, 7, 16, 23, 50, tzinfo=timezone.utc)


def _record(kind="memory", data=None):
    return {
        "schema_version": 1,
        "kind": kind,
        "data": {"id": "memory-1", "content": "remember this"}
        if data is None
        else data,
    }


def _build(records):
    return export_archive.build_export_archive(
        export_id=EXPORT_ID,
        scope="memories",
        requested_at=NOW,
        generated_at=NOW,
        records=records,
    )


def test_archive_is_deterministic_fixed_path_and_self_describing():
    first = _build([_record(data={"content": "=not a formula", "id": "m1"})])
    second = _build([_record(data={"id": "m1", "content": "=not a formula"})])

    assert first.content == second.content
    assert first.sha256 == hashlib.sha256(first.content).digest()
    with zipfile.ZipFile(io.BytesIO(first.content)) as archive:
        assert archive.namelist() == ["memories.jsonl", "manifest.json"]
        assert all(
            not name.startswith(("/", "\\")) and ".." not in name.split("/")
            for name in archive.namelist()
        )
        line = json.loads(archive.read("memories.jsonl"))
        manifest = json.loads(archive.read("manifest.json"))
    assert line["data"]["content"] == "=not a formula"
    assert manifest == first.manifest
    assert manifest["members"][0]["records"] == 1


@pytest.mark.parametrize(
    "key",
    [
        "refresh_token",
        "Refresh-Token",
        " CLIENT SECRET ",
        "credential_ref",
        "route-ciphertext",
        "delivery_claim_hash",
        "subject hash",
        "previous_hash",
    ],
)
def test_archive_rejects_forbidden_fields_at_any_depth(key):
    with pytest.raises(ValueError, match="forbidden"):
        _build([_record(data={"safe": {"nested": {key: "canary-secret"}}})])


def test_archive_rejects_wrong_scope_kind_and_extra_top_level_fields():
    with pytest.raises(ValueError, match="kind"):
        _build([_record(kind="connector")])
    invalid = _record()
    invalid["credential"] = "extra"
    with pytest.raises(ValueError, match="schema"):
        _build([invalid])


def test_archive_rejects_nonfinite_unsupported_and_excessively_nested_values():
    with pytest.raises(ValueError, match="non-finite"):
        _build([_record(data={"confidence": float("nan")})])
    with pytest.raises(ValueError, match="unsupported"):
        _build([_record(data={"raw": b"bytes"})])
    nested = {}
    cursor = nested
    for _ in range(22):
        cursor["child"] = {}
        cursor = cursor["child"]
    with pytest.raises(ValueError, match="nesting"):
        _build([_record(data=nested)])


def test_archive_enforces_record_and_archive_limits(monkeypatch):
    monkeypatch.setattr(export_archive, "MAX_RECORDS", 1)
    with pytest.raises(ValueError, match="record count"):
        _build([_record(), _record()])

    monkeypatch.setattr(export_archive, "MAX_RECORDS", 100)
    monkeypatch.setattr(export_archive, "MAX_ARCHIVE_BYTES", 1)
    with pytest.raises(ValueError, match="archive exceeds"):
        _build([_record()])


def test_archive_rejects_naive_time_and_unknown_scope():
    with pytest.raises(ValueError, match="timezone-aware"):
        export_archive.build_export_archive(
            export_id=EXPORT_ID,
            scope="memories",
            requested_at=NOW.replace(tzinfo=None),
            generated_at=NOW,
            records=[],
        )
    with pytest.raises(ValueError, match="identity or scope"):
        export_archive.build_export_archive(
            export_id=EXPORT_ID,
            scope="everything",
            requested_at=NOW,
            generated_at=NOW,
            records=[],
        )
