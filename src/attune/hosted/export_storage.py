"""Write/delete-only Google Cloud Storage boundary for encrypted exports."""

from __future__ import annotations

from typing import Any
from uuid import UUID

from .customer_export_writer import ObjectNotFound
from .export_archive import MAX_ARCHIVE_BYTES
from .export_crypto import GCM_TAG_BYTES


class GoogleExportObjectStore:
    """Create immutable ciphertext objects and delete only canonical names."""

    def __init__(
        self,
        bucket_name: str,
        *,
        client: Any | None = None,
        _not_found: type[Exception] | tuple[type[Exception], ...] | None = None,
    ):
        if not isinstance(bucket_name, str) or not 3 <= len(bucket_name) <= 63:
            raise ValueError("invalid customer export bucket name")
        if client is None:
            from google.cloud import storage

            client = storage.Client()
        if _not_found is None:
            from google.api_core.exceptions import NotFound

            _not_found = NotFound
        self._bucket = client.bucket(bucket_name)
        self._not_found = _not_found

    def delete(self, object_name: str, *, generation: int | None = None) -> None:
        _validate_object_name(object_name)
        if generation is not None and (
            not isinstance(generation, int) or generation <= 0
        ):
            raise ValueError("export object generation must be positive")
        keyword_arguments = (
            {"if_generation_match": generation} if generation is not None else {}
        )
        try:
            self._bucket.blob(object_name).delete(**keyword_arguments)
        except self._not_found as error:
            raise ObjectNotFound() from error

    def create(self, object_name: str, content: bytes) -> int:
        _validate_object_name(object_name)
        if not isinstance(content, bytes) or not (
            GCM_TAG_BYTES <= len(content) <= MAX_ARCHIVE_BYTES + GCM_TAG_BYTES
        ):
            raise ValueError("invalid encrypted export object")
        blob = self._bucket.blob(object_name)
        blob.upload_from_string(
            content,
            content_type="application/octet-stream",
            if_generation_match=0,
            checksum="crc32c",
        )
        try:
            generation = int(blob.generation)
        except (TypeError, ValueError) as error:
            raise RuntimeError("export upload returned no object generation") from error
        if generation <= 0:
            raise RuntimeError("export upload returned an invalid object generation")
        return generation


def _validate_object_name(object_name: str) -> None:
    if (
        not isinstance(object_name, str)
        or len(object_name) != 48
        or not object_name.startswith("objects/")
        or not object_name.endswith(".bin")
    ):
        raise ValueError("invalid canonical export object name")
    try:
        object_id = UUID(object_name[8:-4])
    except ValueError as error:
        raise ValueError("invalid canonical export object name") from error
    if object_name != f"objects/{object_id}.bin":
        raise ValueError("invalid canonical export object name")
