"""Deterministic, bounded, structurally secret-negative customer export archives."""

from __future__ import annotations

import hashlib
import io
import json
import re
import zipfile
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from uuid import UUID

MAX_RECORD_BYTES = 2 * 1024 * 1024
MAX_RECORDS = 100_000
MAX_ARCHIVE_BYTES = 50 * 1024 * 1024

MEMBER_FIELDS = {
    "account.jsonl": frozenset({"schema_version", "kind", "data"}),
    "conversations.jsonl": frozenset({"schema_version", "kind", "data"}),
    "memories.jsonl": frozenset({"schema_version", "kind", "data"}),
    "activity.jsonl": frozenset({"schema_version", "kind", "data"}),
}
SCOPE_MEMBER = {
    "account": "account.jsonl",
    "conversations": "conversations.jsonl",
    "memories": "memories.jsonl",
    "activity": "activity.jsonl",
}
SCOPE_KINDS = {
    "account": frozenset(
        {"tenant", "principal", "installation", "connector", "policy",
         "autonomy_grant", "onboarding", "channel_preferences",
         "channel_destination"}
    ),
    "conversations": frozenset({"conversation", "conversation_turn"}),
    "memories": frozenset({"memory"}),
    "activity": frozenset({"audit_event", "usage_record"}),
}
FORBIDDEN_KEYS = frozenset(
    {
        "access_token",
        "actor_ref_hash",
        "authorization",
        "client_secret",
        "credential_ref",
        "csrf_hash",
        "delivery_claim_hash",
        "destination_ref_hash",
        "event_hash",
        "external_ref_hash",
        "installation_ref_hash",
        "nonce",
        "password",
        "previous_hash",
        "private_key",
        "refresh_token",
        "route_ciphertext",
        "secret",
        "subject_hash",
        "target_ref_hash",
        "token_hash",
        "wrapped_dek",
    }
)


@dataclass(frozen=True)
class ExportArchive:
    content: bytes
    sha256: bytes
    manifest: dict[str, Any]


def _validate_value(value: Any, *, depth: int = 0) -> None:
    if depth > 20:
        raise ValueError("export value nesting exceeds limit")
    if value is None or isinstance(value, (bool, int, str)):
        return
    if isinstance(value, float):
        if value != value or value in {float("inf"), float("-inf")}:
            raise ValueError("export contains non-finite number")
        return
    if isinstance(value, list):
        for item in value:
            _validate_value(item, depth=depth + 1)
        return
    if isinstance(value, Mapping):
        for key, item in value.items():
            normalized = (
                re.sub(r"[^a-z0-9]+", "_", key.lower()).strip("_")
                if isinstance(key, str)
                else ""
            )
            if (
                not isinstance(key, str)
                or not 1 <= len(key) <= 128
                or normalized in FORBIDDEN_KEYS
            ):
                raise ValueError("export contains forbidden or invalid field")
            _validate_value(item, depth=depth + 1)
        return
    raise ValueError("export contains unsupported value type")


def _json_line(record: Mapping[str, Any], *, allowed_kinds: frozenset[str]) -> bytes:
    if set(record) != MEMBER_FIELDS["account.jsonl"]:
        raise ValueError("export record schema is not exact")
    if record.get("schema_version") != 1:
        raise ValueError("unsupported export record schema")
    kind = record.get("kind")
    if not isinstance(kind, str) or kind not in allowed_kinds:
        raise ValueError("invalid export record kind")
    data = record.get("data")
    if not isinstance(data, Mapping):
        raise ValueError("export record data must be an object")
    _validate_value(data)
    encoded = (
        json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")
    if len(encoded) > MAX_RECORD_BYTES:
        raise ValueError("export record exceeds byte limit")
    return encoded


def _zip_info(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o600 << 16
    info.create_system = 3
    return info


def build_export_archive(
    *,
    export_id: UUID,
    scope: str,
    requested_at: datetime,
    generated_at: datetime,
    records: Iterable[Mapping[str, Any]],
) -> ExportArchive:
    """Build one deterministic fixed-path ZIP and its schema-versioned manifest."""

    if not isinstance(export_id, UUID) or scope not in SCOPE_MEMBER:
        raise ValueError("invalid export archive identity or scope")
    for name, value in (("requested_at", requested_at), ("generated_at", generated_at)):
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError(f"{name} must be timezone-aware")
    member = SCOPE_MEMBER[scope]
    payload = io.BytesIO()
    count = 0
    digest = hashlib.sha256()
    with zipfile.ZipFile(payload, "w", allowZip64=False) as archive:
        with archive.open(_zip_info(member), "w", force_zip64=False) as output:
            for record in records:
                count += 1
                if count > MAX_RECORDS:
                    raise ValueError("export record count exceeds limit")
                line = _json_line(record, allowed_kinds=SCOPE_KINDS[scope])
                digest.update(line)
                output.write(line)
        manifest = {
            "schema_version": 1,
            "export_id": str(export_id),
            "scope": scope,
            "requested_at": requested_at.astimezone(timezone.utc).isoformat(),
            "generated_at": generated_at.astimezone(timezone.utc).isoformat(),
            "members": [
                {
                    "name": member,
                    "records": count,
                    "sha256": digest.hexdigest(),
                }
            ],
        }
        manifest_bytes = json.dumps(
            manifest, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        archive.writestr(_zip_info("manifest.json"), manifest_bytes)
    content = payload.getvalue()
    if len(content) > MAX_ARCHIVE_BYTES:
        raise ValueError("export archive exceeds byte limit")
    return ExportArchive(content, hashlib.sha256(content).digest(), manifest)
