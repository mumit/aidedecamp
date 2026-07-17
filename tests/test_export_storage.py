"""Contract tests for the ciphertext-only export object-store adapter."""

from uuid import UUID

import pytest

from attune.hosted.customer_export_writer import ObjectNotFound
from attune.hosted.export_storage import GoogleExportObjectStore

NAME = f"objects/{UUID('10000000-0000-4000-8000-000000000501')}.bin"


class NotFound(Exception):
    pass


class Blob:
    generation = "37"

    def __init__(self):
        self.upload = None
        self.deleted = None
        self.missing = False

    def upload_from_string(self, content, **kwargs):
        self.upload = (content, kwargs)

    def delete(self, **kwargs):
        if self.missing:
            raise NotFound()
        self.deleted = kwargs


class Bucket:
    def __init__(self):
        self.blobs = {}

    def blob(self, name):
        return self.blobs.setdefault(name, Blob())


class Client:
    def __init__(self):
        self.value = Bucket()

    def bucket(self, name):
        assert name == "attune-customer-exports"
        return self.value


def _store():
    client = Client()
    return GoogleExportObjectStore(
        "attune-customer-exports", client=client, _not_found=NotFound
    ), client


def test_create_is_ciphertext_only_crc_checked_and_create_if_absent():
    store, client = _store()
    content = b"c" * 16
    assert store.create(NAME, content) == 37
    assert client.value.blobs[NAME].upload == (
        content,
        {
            "content_type": "application/octet-stream",
            "if_generation_match": 0,
            "checksum": "crc32c",
        },
    )


def test_delete_supports_exact_generation_and_translates_absence():
    store, client = _store()
    store.delete(NAME, generation=37)
    assert client.value.blobs[NAME].deleted == {"if_generation_match": 37}
    client.value.blobs[NAME].missing = True
    with pytest.raises(ObjectNotFound):
        store.delete(NAME)


@pytest.mark.parametrize(
    "name", ["tenant/customer.zip", "objects/../secret.bin", "objects/not-a-uuid.bin"]
)
def test_store_rejects_noncanonical_names(name):
    store, _ = _store()
    with pytest.raises(ValueError, match="canonical"):
        store.delete(name)


def test_store_rejects_plaintext_sized_or_invalid_metadata():
    store, client = _store()
    with pytest.raises(ValueError, match="encrypted"):
        store.create(NAME, b"short")
    with pytest.raises(ValueError, match="positive"):
        store.delete(NAME, generation=0)
    client.value.blob(NAME).generation = None
    with pytest.raises(RuntimeError, match="no object generation"):
        store.create(NAME, b"c" * 16)
