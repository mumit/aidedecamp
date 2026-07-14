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


def test_quickstart_uses_guided_local_setup():
    readme = (ROOT / "README.md").read_text()
    quickstart = readme.split("## Quick start", 1)[1].split("## Development", 1)[0]

    assert "attune init --target local" in quickstart
    assert "docker compose" not in quickstart
    assert "attune doctor" not in quickstart


def test_qdrant_compose_images_are_pinned_and_loopback_bound():
    compose = (ROOT / "deploy" / "compose.yml").read_text()
    local = (ROOT / "src" / "attune" / "resources" / "local-compose.yml").read_text()

    assert "qdrant/qdrant:latest" not in compose + local
    assert "qdrant/qdrant:v1.18.2" in compose
    assert "qdrant/qdrant:v1.18.2" in local
    assert '"127.0.0.1:6333:6333"' in compose
    assert '"127.0.0.1:6333:6333"' in local


def test_slack_owner_destination_reuses_allowlisted_user_id():
    guide = (ROOT / "docs" / "getting-started.md").read_text()

    assert "ATTUNE_SLACK_CHANNEL=U0123456789" in guide
    assert "conversations_open" not in guide
