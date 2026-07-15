from __future__ import annotations

from types import SimpleNamespace

import pytest

from attune.hosted import provision_identity


class Cursor:
    def __init__(self, rows):
        self.rows = rows
        self.calls = []

    def execute(self, statement, parameters):
        self.calls.append((statement, parameters))

    def fetchall(self):
        return self.rows

    def close(self):
        pass


class Connection:
    def __init__(self, rows):
        self.cursor_value = Cursor(rows)
        self.commits = 0
        self.rollbacks = 0

    def cursor(self):
        return self.cursor_value

    def commit(self):
        self.commits += 1

    def rollback(self):
        self.rollbacks += 1

    def close(self):
        pass


def environment(monkeypatch):
    values = {
        "ATTUNE_IDENTITY_BOOTSTRAP_SECRET": (
            "projects/attune-development-502421/"
            "secrets/attune-development-identity-bootstrap"
        ),
        "ATTUNE_IDENTITY_ISSUER": (
            "https://securetoken.google.com/attune-development-502421"
        ),
        "ATTUNE_INITIAL_TENANT_SLUG": "owner-dev",
        "ATTUNE_INITIAL_TENANT_REGION": "northamerica-northeast1",
    }
    for name, value in values.items():
        monkeypatch.setenv(name, value)


def test_identity_provisioner_is_fixed_content_free_and_commits(monkeypatch, capsys):
    environment(monkeypatch)
    connection = Connection([("tenant-id", "principal-id", True)])
    owner = SimpleNamespace(closed=False)
    owner.close = lambda: setattr(owner, "closed", True)
    monkeypatch.setattr(
        provision_identity, "_subject_hash_from_secret", lambda resource: "a" * 64
    )
    monkeypatch.setattr(
        provision_identity, "_cloud_sql_connection", lambda: (owner, connection)
    )

    assert provision_identity.main([]) == 0
    assert connection.commits == 1
    assert connection.rollbacks == 0
    assert owner.closed
    statement, parameters = connection.cursor_value.calls[0]
    assert "provision_initial_identity" in statement
    assert parameters[0] == "a" * 64
    output = capsys.readouterr().out
    assert output == "initial identity mapping verified; created=true\n"
    assert "tenant-id" not in output
    assert "principal-id" not in output
    assert "a" * 8 not in output


def test_identity_provisioner_rejects_arguments_and_invalid_secret_name(monkeypatch):
    environment(monkeypatch)
    with pytest.raises(ValueError, match="accepts no runtime arguments"):
        provision_identity.main(["--subject", "unsafe"])

    monkeypatch.setenv("ATTUNE_IDENTITY_BOOTSTRAP_SECRET", "not-a-resource")
    with pytest.raises(ValueError, match="missing or invalid"):
        provision_identity.main([])
