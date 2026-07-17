"""Envelope encryption for dormant hosted customer-export archives."""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from uuid import UUID

from .export_archive import MAX_ARCHIVE_BYTES, SCOPE_MEMBER, ExportArchive
from .vault_crypto import KeyWrapper

FORMAT_VERSION = 1
DEK_BYTES = 32
NONCE_BYTES = 12
GCM_TAG_BYTES = 16
MAX_WRAPPED_DEK_BYTES = 65_536


@dataclass(frozen=True)
class EncryptedExportArchive:
    ciphertext: bytes
    nonce: bytes
    wrapped_dek: bytes
    key_resource: str
    plaintext_sha256: bytes
    ciphertext_sha256: bytes
    plaintext_bytes: int
    format_version: int = FORMAT_VERSION


class ExportEnvelopeCipher:
    """Use one random AES-256-GCM DEK and fixed authenticated context per export."""

    def __init__(self, wrapper: KeyWrapper):
        if not wrapper.key_resource:
            raise ValueError("an export KMS key resource is required")
        self._wrapper = wrapper

    def encrypt(
        self,
        archive: ExportArchive,
        *,
        tenant_id: UUID,
        export_id: UUID,
        scope: str,
        object_id: UUID,
    ) -> EncryptedExportArchive:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM

        plaintext = _validated_archive(archive, export_id=export_id, scope=scope)
        aad = _associated_data(
            tenant_id=tenant_id,
            export_id=export_id,
            scope=scope,
            object_id=object_id,
            plaintext_sha256=archive.sha256,
            plaintext_bytes=len(plaintext),
        )
        dek = bytearray(os.urandom(DEK_BYTES))
        nonce = os.urandom(NONCE_BYTES)
        try:
            ciphertext = AESGCM(bytes(dek)).encrypt(nonce, plaintext, aad)
            wrapped_dek = self._wrapper.wrap(bytes(dek))
        finally:
            dek[:] = bytes(len(dek))
        if not 1 <= len(wrapped_dek) <= MAX_WRAPPED_DEK_BYTES:
            raise ValueError("wrapped export DEK exceeds the size limit")
        return EncryptedExportArchive(
            ciphertext=ciphertext,
            nonce=nonce,
            wrapped_dek=wrapped_dek,
            key_resource=self._wrapper.key_resource,
            plaintext_sha256=archive.sha256,
            ciphertext_sha256=hashlib.sha256(ciphertext).digest(),
            plaintext_bytes=len(plaintext),
        )

    def decrypt(
        self,
        encrypted: EncryptedExportArchive,
        *,
        tenant_id: UUID,
        export_id: UUID,
        scope: str,
        object_id: UUID,
    ) -> bytes:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM

        _validate_encrypted(encrypted)
        if encrypted.key_resource != self._wrapper.key_resource:
            raise ValueError("export KMS key does not match this gateway")
        if hashlib.sha256(encrypted.ciphertext).digest() != encrypted.ciphertext_sha256:
            raise ValueError("encrypted export digest mismatch")
        dek = bytearray(self._wrapper.unwrap(encrypted.wrapped_dek))
        if len(dek) != DEK_BYTES:
            dek[:] = bytes(len(dek))
            raise ValueError("unwrapped export DEK must be 32 bytes")
        try:
            plaintext = AESGCM(bytes(dek)).decrypt(
                encrypted.nonce,
                encrypted.ciphertext,
                _associated_data(
                    tenant_id=tenant_id,
                    export_id=export_id,
                    scope=scope,
                    object_id=object_id,
                    plaintext_sha256=encrypted.plaintext_sha256,
                    plaintext_bytes=encrypted.plaintext_bytes,
                ),
            )
        finally:
            dek[:] = bytes(len(dek))
        if len(plaintext) != encrypted.plaintext_bytes:
            raise ValueError("decrypted export size mismatch")
        if hashlib.sha256(plaintext).digest() != encrypted.plaintext_sha256:
            raise ValueError("decrypted export digest mismatch")
        return plaintext


def _validated_archive(
    archive: ExportArchive, *, export_id: UUID, scope: str
) -> bytes:
    if not isinstance(archive, ExportArchive):
        raise TypeError("archive must be an ExportArchive")
    if not isinstance(export_id, UUID) or scope not in SCOPE_MEMBER:
        raise ValueError("invalid export archive identity or scope")
    if not isinstance(archive.content, bytes) or len(archive.content) > MAX_ARCHIVE_BYTES:
        raise ValueError("export archive exceeds the size limit")
    if not isinstance(archive.sha256, bytes) or len(archive.sha256) != 32:
        raise ValueError("export archive digest is invalid")
    if hashlib.sha256(archive.content).digest() != archive.sha256:
        raise ValueError("export archive digest mismatch")
    if (
        archive.manifest.get("schema_version") != 1
        or archive.manifest.get("export_id") != str(export_id)
        or archive.manifest.get("scope") != scope
    ):
        raise ValueError("export archive manifest context mismatch")
    return archive.content


def _validate_encrypted(encrypted: EncryptedExportArchive) -> None:
    if not isinstance(encrypted, EncryptedExportArchive):
        raise TypeError("encrypted archive has the wrong type")
    if encrypted.format_version != FORMAT_VERSION:
        raise ValueError("unsupported export encryption format")
    if len(encrypted.nonce) != NONCE_BYTES:
        raise ValueError("export nonce must be 12 bytes")
    if not 1 <= len(encrypted.wrapped_dek) <= MAX_WRAPPED_DEK_BYTES:
        raise ValueError("wrapped export DEK exceeds the size limit")
    if len(encrypted.plaintext_sha256) != 32 or len(encrypted.ciphertext_sha256) != 32:
        raise ValueError("export digest is invalid")
    if not 0 <= encrypted.plaintext_bytes <= MAX_ARCHIVE_BYTES:
        raise ValueError("export plaintext size is invalid")
    if len(encrypted.ciphertext) != encrypted.plaintext_bytes + GCM_TAG_BYTES:
        raise ValueError("export ciphertext size is invalid")


def _associated_data(
    *,
    tenant_id: UUID,
    export_id: UUID,
    scope: str,
    object_id: UUID,
    plaintext_sha256: bytes,
    plaintext_bytes: int,
) -> bytes:
    if not all(isinstance(value, UUID) for value in (tenant_id, export_id, object_id)):
        raise TypeError("tenant, export, and object identifiers must be UUIDs")
    if scope not in SCOPE_MEMBER:
        raise ValueError("invalid export scope")
    if not isinstance(plaintext_sha256, bytes) or len(plaintext_sha256) != 32:
        raise ValueError("export archive digest is invalid")
    if not 0 <= plaintext_bytes <= MAX_ARCHIVE_BYTES:
        raise ValueError("export archive size is invalid")
    return json.dumps(
        {
            "export_id": str(export_id),
            "format_version": FORMAT_VERSION,
            "object_id": str(object_id),
            "plaintext_bytes": plaintext_bytes,
            "plaintext_sha256": plaintext_sha256.hex(),
            "scope": scope,
            "tenant_id": str(tenant_id),
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("ascii")
