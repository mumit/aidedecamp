"""Secure, resumable setup workflow tests. All external effects are injected."""

from __future__ import annotations

import json
import os
import subprocess

import pytest

from attune.cli.init_cmd import run_init
from attune.cli.env_file import attune_env_exact, load_attune_env_exact
from attune.cli.local_setup import build_local_plan, compose_file
from attune.cli.setup_cmd import run_repair, run_status
from attune.cli.setup_state import SetupState, SetupStateError, setup_state_path


def _answers(data_dir: str):
    values = {
        "Data directory": data_dir,
        "mailbox email": "owner@example.com",
        "Default chat model": "test-model",
        "Embedding model": "test-embedding",
        "Embedding dimensions": "1536",
    }

    def ask(prompt: str) -> str:
        return next((value for key, value in values.items() if key in prompt), "")

    return ask


def _success(command):
    return subprocess.CompletedProcess(command, 0, stdout="started", stderr="")


def test_local_plan_is_fixed_secret_free_and_loopback_only():
    plan = build_local_plan()
    content = open(compose_file(), encoding="utf-8").read()

    assert isinstance(plan.command, tuple)
    assert plan.plan_id == "local-qdrant-v1"
    assert len(plan.digest) == 64
    assert plan.command[:2] == ("docker", "compose")
    assert "qdrant/qdrant:v1.18.2" in content
    assert "qdrant/qdrant:latest" not in content
    assert '"127.0.0.1:6333:6333"' in content
    assert "env_file" not in content
    assert "ATTUNE_" not in content


def test_exact_setup_env_removes_cleared_managed_values(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text(
        "ATTUNE_LLM_API_KEY=\n"
        "ATTUNE_MODEL_DEFAULT=file-model\n"
        "CUSTOM_SETTING=file-custom\n"
    )
    monkeypatch.setenv("ATTUNE_LLM_API_KEY", "stale-secret")
    monkeypatch.setenv("ATTUNE_OLD_SETTING", "stale-value")
    monkeypatch.setenv("CUSTOM_SETTING", "process-custom")

    load_attune_env_exact(str(env_file))

    assert os.environ["ATTUNE_LLM_API_KEY"] == ""
    assert os.environ["ATTUNE_MODEL_DEFAULT"] == "file-model"
    assert "ATTUNE_OLD_SETTING" not in os.environ
    assert os.environ["CUSTOM_SETTING"] == "process-custom"


def test_exact_setup_env_context_restores_process_values(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text("ATTUNE_MODEL_DEFAULT=file-model\n")
    monkeypatch.setenv("ATTUNE_MODEL_DEFAULT", "process-model")
    monkeypatch.setenv("ATTUNE_ONLY_IN_PROCESS", "keep-me")

    with attune_env_exact(str(env_file)):
        assert os.environ["ATTUNE_MODEL_DEFAULT"] == "file-model"
        assert "ATTUNE_ONLY_IN_PROCESS" not in os.environ

    assert os.environ["ATTUNE_MODEL_DEFAULT"] == "process-model"
    assert os.environ["ATTUNE_ONLY_IN_PROCESS"] == "keep-me"


def test_local_init_applies_validates_and_records_no_secrets(tmp_path):
    data_dir = str(tmp_path / "data")
    env_file = str(tmp_path / ".env")
    commands = []
    doctor_calls = []

    def runner(command):
        commands.append(tuple(command))
        return _success(command)

    def doctor(**kwargs):
        doctor_calls.append(kwargs)
        kwargs["out"]("PASS  injected doctor")
        return 0

    lines = []
    code = run_init(
        env_file=env_file,
        target="local",
        yes=True,
        ask=_answers(data_dir),
        ask_secret=lambda prompt: "top-secret" if "LLM API" in prompt else "",
        local_runner=runner,
        doctor=doctor,
        out=lines.append,
    )

    assert code == 0
    assert len(commands) == 1
    assert commands[0][:2] == ("docker", "compose")
    assert len(doctor_calls) == 1
    path = setup_state_path(data_dir)
    state_text = open(path, encoding="utf-8").read()
    state = json.loads(state_text)
    assert "top-secret" not in state_text
    assert state["schema_version"] == 1
    assert state["steps"]["configure"]["status"] == "succeeded"
    assert state["steps"]["apply"]["status"] == "succeeded"
    assert state["steps"]["validate"]["status"] == "succeeded"
    assert state["resources"] == [
        "docker-compose-project:attune",
        "service:qdrant",
        "volume:qdrant_data",
    ]
    assert oct(os.stat(path).st_mode & 0o777) == "0o600"
    assert all("top-secret" not in line for line in lines)


def test_local_init_decline_preserves_config_and_resumable_state(tmp_path):
    data_dir = str(tmp_path / "data")
    lines = []
    code = run_init(
        env_file=str(tmp_path / ".env"),
        target="local",
        ask=_answers(data_dir),
        ask_secret=lambda prompt: "",
        local_runner=lambda command: pytest.fail("declined plan must not run"),
        doctor=lambda **kwargs: pytest.fail("declined plan must not validate"),
        out=lines.append,
    )

    assert code == 0
    state = json.loads(open(setup_state_path(data_dir), encoding="utf-8").read())
    assert state["steps"]["apply"]["status"] == "declined"
    assert any("Local deployment plan (" in line for line in lines)
    assert any("Configuration is saved" in line for line in lines)


def test_local_init_failure_is_recorded_and_safe_to_retry(tmp_path):
    data_dir = str(tmp_path / "data")
    env_file = str(tmp_path / ".env")
    calls = 0

    def runner(command):
        nonlocal calls
        calls += 1
        if calls == 1:
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="daemon down")
        return _success(command)

    common = dict(
        env_file=env_file,
        target="local",
        yes=True,
        ask=_answers(data_dir),
        ask_secret=lambda prompt: "",
        local_runner=runner,
        doctor=lambda **kwargs: 0,
        out=lambda line: None,
    )
    assert run_init(**common) == 1
    failed = json.loads(open(setup_state_path(data_dir), encoding="utf-8").read())
    assert failed["steps"]["apply"]["status"] == "failed"

    assert run_init(**common) == 0
    succeeded = json.loads(open(setup_state_path(data_dir), encoding="utf-8").read())
    assert succeeded["steps"]["apply"]["status"] == "succeeded"
    assert succeeded["steps"]["validate"]["status"] == "succeeded"
    assert calls == 2


def test_setup_state_refuses_another_environment_file(tmp_path):
    data_dir = str(tmp_path / "data")
    path = setup_state_path(data_dir)
    state = SetupState.load_or_create(
        path,
        target="local",
        env_file=str(tmp_path / "first.env"),
        data_dir=data_dir,
    )
    state.save(path)

    with pytest.raises(SetupStateError, match="different environment"):
        SetupState.load_or_create(
            path,
            target="local",
            env_file=str(tmp_path / "second.env"),
            data_dir=data_dir,
        )


def test_setup_state_refuses_symlink_and_broad_permissions(tmp_path):
    if os.name != "posix":
        pytest.skip("POSIX permission and symlink semantics")
    data_dir = str(tmp_path / "data")
    env_file = str(tmp_path / ".env")
    path = setup_state_path(data_dir)
    state = SetupState.load_or_create(
        path, target="local", env_file=env_file, data_dir=data_dir
    )
    state.save(path)
    os.chmod(path, 0o644)
    with pytest.raises(SetupStateError, match="owner-only"):
        SetupState.load_or_create(
            path, target="local", env_file=env_file, data_dir=data_dir
        )

    os.unlink(path)
    target = tmp_path / "other-state.json"
    target.write_text("{}")
    os.symlink(target, path)
    with pytest.raises(SetupStateError, match="symbolic link"):
        SetupState.load_or_create(
            path, target="local", env_file=env_file, data_dir=data_dir
        )


def test_changed_configuration_invalidates_applied_and_validated_steps(tmp_path):
    data_dir = str(tmp_path / "data")
    path = setup_state_path(data_dir)
    state = SetupState.load_or_create(
        path,
        target="local",
        env_file=str(tmp_path / ".env"),
        data_dir=data_dir,
    )
    state.record_configuration("first")
    state.set_step("apply", "succeeded")
    state.set_step("validate", "succeeded")
    state.resources = ["service:qdrant"]

    state.record_configuration("second")

    assert state.steps["apply"].status == "not_started"
    assert state.steps["validate"].status == "not_started"
    assert state.resources == []


def test_changed_plan_invalidates_applied_and_validated_steps(tmp_path):
    data_dir = str(tmp_path / "data")
    state = SetupState.load_or_create(
        setup_state_path(data_dir),
        target="local",
        env_file=str(tmp_path / ".env"),
        data_dir=data_dir,
    )
    state.record_configuration("config")
    state.record_plan("first-plan")
    state.set_step("apply", "succeeded")
    state.set_step("validate", "succeeded")
    state.resources = ["service:qdrant"]

    state.record_plan("second-plan")

    assert state.steps["apply"].status == "not_started"
    assert state.steps["validate"].status == "not_started"
    assert state.resources == []


def test_status_is_secret_free_and_reports_complete_setup(tmp_path):
    data_dir = str(tmp_path / "data")
    env_file = str(tmp_path / ".env")
    assert run_init(
        env_file=env_file,
        target="local",
        yes=True,
        ask=_answers(data_dir),
        ask_secret=lambda prompt: "status-secret" if "LLM API" in prompt else "",
        local_runner=_success,
        doctor=lambda **kwargs: 0,
        out=lambda line: None,
    ) == 0

    lines = []
    assert run_status(env_file=env_file, out=lines.append) == 0
    rendered = "\n".join(lines)
    assert "status-secret" not in rendered
    assert "SUCCEEDED" in rendered
    assert "service:qdrant" in rendered


def test_status_detects_environment_drift(tmp_path):
    data_dir = str(tmp_path / "data")
    env_file = str(tmp_path / ".env")
    assert run_init(
        env_file=env_file,
        target="local",
        yes=True,
        ask=_answers(data_dir),
        ask_secret=lambda prompt: "",
        local_runner=_success,
        doctor=lambda **kwargs: 0,
        out=lambda line: None,
    ) == 0
    with open(env_file, "a", encoding="utf-8") as fh:
        fh.write("ATTUNE_POLL_SECONDS=300\n")

    lines = []
    assert run_status(env_file=env_file, out=lines.append) == 1
    assert any("STALE" in line and "environment changed" in line for line in lines)


def test_status_detects_plan_drift(tmp_path):
    data_dir = str(tmp_path / "data")
    env_file = str(tmp_path / ".env")
    assert run_init(
        env_file=env_file,
        target="local",
        yes=True,
        ask=_answers(data_dir),
        ask_secret=lambda prompt: "",
        local_runner=_success,
        doctor=lambda **kwargs: 0,
        out=lambda line: None,
    ) == 0
    path = setup_state_path(data_dir)
    state = json.loads(open(path, encoding="utf-8").read())
    state["plan_digest"] = "old-plan"
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(state, fh)
    os.chmod(path, 0o600)

    lines = []
    assert run_status(env_file=env_file, out=lines.append) == 1
    assert any("STALE" in line and "plan changed" in line for line in lines)


def test_status_check_combines_setup_and_live_health(tmp_path):
    data_dir = str(tmp_path / "data")
    env_file = tmp_path / ".env"
    env_file.write_text(f"ATTUNE_DATA_DIR={data_dir}\n")
    state = SetupState.load_or_create(
        setup_state_path(data_dir),
        target="local",
        env_file=str(env_file),
        data_dir=data_dir,
    )
    state.record_configuration("digest")
    state.save(setup_state_path(data_dir))

    assert run_status(
        env_file=str(env_file),
        check=True,
        doctor=lambda **kwargs: 0,
        out=lambda line: None,
    ) == 1


def test_repair_reapplies_owned_plan_and_revalidates(tmp_path):
    data_dir = str(tmp_path / "data")
    env_file = str(tmp_path / ".env")
    commands = []

    def runner(command):
        commands.append(tuple(command))
        return _success(command)

    common = dict(
        env_file=env_file,
        target="local",
        yes=True,
        ask=_answers(data_dir),
        ask_secret=lambda prompt: "",
        local_runner=runner,
        doctor=lambda **kwargs: 0,
        out=lambda line: None,
    )
    assert run_init(**common) == 0
    assert run_repair(
        env_file=env_file,
        yes=True,
        local_runner=runner,
        doctor=lambda **kwargs: 0,
        out=lambda line: None,
    ) == 0
    assert len(commands) == 2


def test_repair_refuses_unowned_resources(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text(f"ATTUNE_DATA_DIR={tmp_path / 'data'}\n")

    assert run_repair(
        env_file=str(env_file),
        yes=True,
        local_runner=lambda command: pytest.fail("must not infer resources"),
        doctor=lambda **kwargs: pytest.fail("must not validate"),
        out=lambda line: None,
    ) == 1
