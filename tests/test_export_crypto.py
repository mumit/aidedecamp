"""Adversarial tests for the customer-export encryption envelope."""

from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timezone
from uuid import UUID

import pytest

from attune.hosted.export_archive import build_export_archive
from attune.hosted.export_crypto import ExportEnvelopeCipher

TENANT = UUID("10000000-0000-4000-8000-000000000301")
EXPORT = UUID("10000000-0000-4000-8000-000000000302")
OBJECT = UUID("10000000-0000-4000-8000-000000000303")
NOW = datetime(2026, 7, 17, tzinfo=timezone.utc)


class Wrapper:
    key_resource = "projects/test/locations/test/keyRings/test/cryptoKeys/customer-export"

    def wrap(self, value):
        return bytes(byte ^ 0xA5 for byte in value)

    def unwrap(self, value):
        return bytes(byte ^ 0xA5 for byte in value)


def _archive():
    return build_export_archive(
        export_id=EXPORT,
        scope="memories",
        requested_at=NOW,
        generated_at=NOW,
        records=[
            {
                "schema_version": 1,
                "kind": "memory",
                "data": {"id": "memory-1", "content": "customer data"},
            }
        ],
    )


def _context():
    return {
        "tenant_id": TENANT,
        "export_id": EXPORT,
        "scope": "memories",
        "object_id": OBJECT,
    }


def test_export_envelope_round_trip_uses_fresh_deks_and_nonces():
    cipher = ExportEnvelopeCipher(Wrapper())
    archive = _archive()
    first = cipher.encrypt(archive, **_context())
    second = cipher.encrypt(archive, **_context())

    assert first.ciphertext != second.ciphertext
    assert first.nonce != second.nonce
    assert first.wrapped_dek != second.wrapped_dek
    assert cipher.decrypt(first, **_context()) == archive.content


@pytest.mark.parametrize("field", ["tenant_id", "export_id", "scope", "object_id"])
def test_export_envelope_rejects_authenticated_context_substitution(field):
    cipher = ExportEnvelopeCipher(Wrapper())
    encrypted = cipher.encrypt(_archive(), **_context())
    context = _context()
    context[field] = {
        "tenant_id": UUID("20000000-0000-4000-8000-000000000301"),
        "export_id": UUID("20000000-0000-4000-8000-000000000302"),
        "scope": "account",
        "object_id": UUID("20000000-0000-4000-8000-000000000303"),
    }[field]
    with pytest.raises(Exception):
        cipher.decrypt(encrypted, **context)


@pytest.mark.parametrize(
    "field,value",
    [
        ("ciphertext", b"x"),
        ("nonce", b"x"),
        ("wrapped_dek", b""),
        ("plaintext_sha256", b"x" * 32),
        ("ciphertext_sha256", b"x" * 32),
        ("plaintext_bytes", 1),
        ("format_version", 2),
    ],
)
def test_export_envelope_rejects_tampered_metadata(field, value):
    cipher = ExportEnvelopeCipher(Wrapper())
    encrypted = cipher.encrypt(_archive(), **_context())
    with pytest.raises(Exception):
        cipher.decrypt(replace(encrypted, **{field: value}), **_context())


def test_export_envelope_rejects_wrong_key_and_forged_archive_context():
    archive = _archive()
    cipher = ExportEnvelopeCipher(Wrapper())
    encrypted = cipher.encrypt(archive, **_context())

    class OtherWrapper(Wrapper):
        key_resource = "projects/test/locations/test/keyRings/test/cryptoKeys/other"

    with pytest.raises(ValueError, match="KMS key"):
        ExportEnvelopeCipher(OtherWrapper()).decrypt(encrypted, **_context())
    with pytest.raises(ValueError, match="manifest context"):
        cipher.encrypt(
            replace(archive, manifest={**archive.manifest, "scope": "account"}),
            **_context(),
        )
    with pytest.raises(ValueError, match="digest mismatch"):
        cipher.encrypt(replace(archive, content=archive.content + b"x"), **_context())
