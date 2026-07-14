"""Documentation consistency tests."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_every_example_environment_variable_is_documented():
    example = (ROOT / ".env.example").read_text()
    reference = (ROOT / "docs" / "configuration.md").read_text()

    example_keys = set(
        re.findall(r"^(?:# )?([A-Z][A-Z0-9_]+)=", example, flags=re.MULTILINE)
    )
    documented_keys = set(
        re.findall(r"^\| `([A-Z][A-Z0-9_]+)` \|", reference, flags=re.MULTILINE)
    )

    assert documented_keys == example_keys
