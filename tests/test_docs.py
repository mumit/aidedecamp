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


def test_quickstart_starts_qdrant_before_doctor():
    readme = (ROOT / "README.md").read_text()
    quickstart = readme.split("## Quick start", 1)[1].split("## Development", 1)[0]

    assert "docker compose -f deploy/compose.yml up -d" in quickstart
    assert quickstart.index("docker compose") < quickstart.index("attune doctor")


def test_slack_owner_destination_reuses_allowlisted_user_id():
    guide = (ROOT / "docs" / "getting-started.md").read_text()

    assert "ATTUNE_SLACK_CHANNEL=U0123456789" in guide
    assert "conversations_open" not in guide
