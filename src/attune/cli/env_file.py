"""Load an explicit Attune environment file without retaining stale settings."""

from __future__ import annotations

from contextlib import contextmanager
import os
from typing import Iterator

from dotenv import dotenv_values


_EXACT_KEYS = frozenset({"GOOGLE_PROJECT_ID"})
_PREFIXES = ("ATTUNE_", "SLACK_")


def is_attune_setting(name: str) -> bool:
    return name in _EXACT_KEYS or name.startswith(_PREFIXES)


def load_attune_env_exact(path: str) -> None:
    """Replace Attune-managed process values with exactly those in *path*.

    ``load_dotenv(..., override=True)`` overwrites present assignments but does
    not remove a value that was cleared from the file.  Setup validation and
    repair must not accidentally validate such a stale credential.  Unknown
    process variables are deliberately preserved.
    """
    values = dotenv_values(path)
    for name in tuple(os.environ):
        if is_attune_setting(name):
            os.environ.pop(name, None)
    for name, value in values.items():
        if name and value is not None and is_attune_setting(name):
            os.environ[name] = value


@contextmanager
def attune_env_exact(path: str) -> Iterator[None]:
    """Temporarily expose exactly one Attune environment to in-process code."""
    previous = {
        name: value
        for name, value in os.environ.items()
        if is_attune_setting(name)
    }
    load_attune_env_exact(path)
    try:
        yield
    finally:
        for name in tuple(os.environ):
            if is_attune_setting(name):
                os.environ.pop(name, None)
        os.environ.update(previous)
