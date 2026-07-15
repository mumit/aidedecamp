from __future__ import annotations

import pytest

from attune.hosted.kms_smoke import validate


class Wrapper:
    def __init__(self, corrupt=False):
        self.corrupt = corrupt

    def wrap(self, plaintext):
        return bytes(byte ^ 0xA5 for byte in plaintext)

    def unwrap(self, wrapped):
        plaintext = bytes(byte ^ 0xA5 for byte in wrapped)
        return plaintext[:-1] + b"x" if self.corrupt else plaintext


def test_kms_smoke_requires_an_exact_round_trip():
    validate(Wrapper())
    with pytest.raises(RuntimeError):
        validate(Wrapper(corrupt=True))
