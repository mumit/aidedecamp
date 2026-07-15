"""Secret-free live round-trip check for the connector credential KMS key."""

from __future__ import annotations

import hmac
import os
from typing import Protocol

from .vault_crypto import GoogleKmsKeyWrapper


class Wrapper(Protocol):
    def wrap(self, plaintext_dek: bytes) -> bytes: ...

    def unwrap(self, wrapped_dek: bytes) -> bytes: ...


def validate(wrapper: Wrapper) -> None:
    plaintext = bytearray(os.urandom(32))
    recovered = bytearray()
    try:
        recovered = bytearray(wrapper.unwrap(wrapper.wrap(bytes(plaintext))))
        if not hmac.compare_digest(plaintext, recovered):
            raise RuntimeError("connector KMS round trip failed")
    finally:
        plaintext[:] = bytes(len(plaintext))
        recovered[:] = bytes(len(recovered))


def main() -> None:
    validate(GoogleKmsKeyWrapper(os.environ["ATTUNE_CONNECTOR_KMS_KEY"]))
    print("PASS connector KMS round trip")


if __name__ == "__main__":
    main()
