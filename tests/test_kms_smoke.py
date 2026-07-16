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
        return (
            plaintext[:-1] + bytes([plaintext[-1] ^ 0x01])
            if self.corrupt
            else plaintext
        )


def test_kms_smoke_requires_an_exact_round_trip(monkeypatch):
    validate(Wrapper())
    # The former test replaced the last byte with b"x" and therefore failed
    # nondeterministically when os.urandom already ended in b"x".
    monkeypatch.setattr("attune.hosted.kms_smoke.os.urandom", lambda size: b"x" * size)
    with pytest.raises(RuntimeError):
        validate(Wrapper(corrupt=True))
