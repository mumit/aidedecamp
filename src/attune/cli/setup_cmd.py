"""Inspect and repair the resumable local setup without exposing secrets."""

from __future__ import annotations

import hashlib
import os
import subprocess
from typing import Callable

from dotenv import dotenv_values

from .env_file import attune_env_exact
from .init_cmd import DEFAULT_DATA_DIR, _run_local_target
from .local_setup import build_local_plan
from .setup_state import STEP_NAMES, SetupState, SetupStateError, setup_state_path


def _setup_context(env_file: str) -> tuple[str, str, str]:
    env_file = os.path.abspath(env_file)
    if not os.path.isfile(env_file):
        raise SetupStateError(f"environment file does not exist: {env_file}")
    with open(env_file, encoding="utf-8") as fh:
        content = fh.read()
    values = dotenv_values(env_file)
    data_dir = os.path.abspath(
        os.path.expanduser(str(values.get("ATTUNE_DATA_DIR") or DEFAULT_DATA_DIR))
    )
    return env_file, data_dir, content


def run_status(
    *,
    env_file: str = ".env",
    check: bool = False,
    doctor: Callable[..., int] | None = None,
    out: Callable[[str], None] = print,
) -> int:
    try:
        resolved_env, data_dir, content = _setup_context(env_file)
        path = setup_state_path(data_dir)
        if not os.path.exists(path):
            out(f"No recorded setup state at {path}.")
            out("Run attune init --target local to configure and provision locally.")
            return 1
        state = SetupState.load_or_create(
            path,
            target="local",
            env_file=resolved_env,
            data_dir=data_dir,
        )
    except SetupStateError as exc:
        out(f"Setup status unavailable: {exc}")
        return 1

    out(f"Setup target: {state.target} (schema {state.schema_version})")
    out(f"State: {path}")
    current_digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
    configuration_current = state.config_digest == current_digest
    plan_current = state.plan_digest == build_local_plan().digest
    if not configuration_current:
        out("STALE       configure  — environment changed after the recorded setup")
    for name in STEP_NAMES:
        if name == "configure" and not configuration_current:
            continue
        if name == "apply" and not plan_current:
            out("STALE       apply      — packaged deployment plan changed")
            continue
        step = state.steps[name]
        suffix = f" — {step.detail}" if step.detail else ""
        out(f"{step.status.upper():11} {name:10}{suffix}")
    if state.resources:
        out("Resources: " + ", ".join(state.resources))

    complete = configuration_current and plan_current and all(
        state.steps[name].status == "succeeded" for name in STEP_NAMES
    )
    if not check:
        return 0 if complete else 1
    if doctor is None:
        from .doctor import run_doctor

        doctor = run_doctor
    out("")
    with attune_env_exact(resolved_env):
        doctor_code = int(doctor(out=out) or 0)
    return doctor_code or (0 if complete else 1)


def run_repair(
    *,
    env_file: str = ".env",
    yes: bool = False,
    ask: Callable[[str], str] = input,
    local_runner: (
        Callable[
            [list[str] | tuple[str, ...]], subprocess.CompletedProcess[str]
        ]
        | None
    ) = None,
    doctor: Callable[..., int] | None = None,
    out: Callable[[str], None] = print,
) -> int:
    try:
        resolved_env, data_dir, content = _setup_context(env_file)
    except SetupStateError as exc:
        out(f"Repair refused: {exc}")
        return 1
    path = setup_state_path(data_dir)
    if not os.path.exists(path):
        out(f"Repair refused: no recorded local setup at {path}")
        out("Run attune init --target local first; repair will not infer ownership.")
        return 1
    return _run_local_target(
        env_file=resolved_env,
        data_dir=data_dir,
        content=content,
        ask=ask,
        yes=yes,
        runner=local_runner,
        doctor=doctor,
        force_apply=True,
        out=out,
    )
