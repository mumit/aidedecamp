"""The ``aidedecamp`` command-line interface (roadmap prompt 08).

Until this existed, the only entrypoint was ``python -m aidedecamp`` — which
immediately needs a fully configured environment and live GCP — and setup was
a 600-line manual runbook. The CLI is the human front door:

    aidedecamp init      interactive setup wizard (writes .env)
    aidedecamp doctor    validate every credential/resource, with fix hints
    aidedecamp brief     assemble one morning brief and print it
    aidedecamp run       start the always-on process (doctor-gated)
    aidedecamp memory    (subcommand group — arrives with roadmap M4)
    aidedecamp autonomy  (subcommand group — arrives with roadmap M4)

Stdlib ``argparse`` — a CLI with five subcommands doesn't justify a click/
typer dependency. Heavy imports happen inside subcommands so
``aidedecamp --help`` works in a bare install.
"""

from __future__ import annotations

import argparse
from typing import Any


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aidedecamp",
        description="A self-learning workspace assistant over Gmail, "
        "Calendar, Google Chat, and Slack.",
    )
    sub = parser.add_subparsers(dest="command")

    p_init = sub.add_parser(
        "init", help="interactive setup: write .env, bootstrap Google OAuth"
    )
    p_init.add_argument("--env-file", default=".env", help="where to write settings")
    p_init.add_argument(
        "--force", action="store_true", help="overwrite an existing env file"
    )
    p_init.set_defaults(func=_cmd_init)

    p_doctor = sub.add_parser(
        "doctor", help="validate configuration, credentials, and services"
    )
    p_doctor.set_defaults(func=_cmd_doctor)

    p_brief = sub.add_parser("brief", help="assemble one morning brief and print it")
    p_brief.add_argument(
        "--post", action="store_true",
        help="also post it to the configured channels",
    )
    p_brief.set_defaults(func=_cmd_brief)

    p_run = sub.add_parser("run", help="start the always-on process")
    p_run.add_argument(
        "--no-checks", action="store_true",
        help="skip the fatal-checks doctor pass before starting",
    )
    p_run.set_defaults(func=_cmd_run)

    for group in ("memory", "autonomy"):
        p = sub.add_parser(group, help=f"{group} management (coming in M4)")
        p.set_defaults(func=_cmd_coming_soon, group=group)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not hasattr(args, "func"):
        parser.print_help()
        return 1
    return int(args.func(args) or 0)


# --- subcommand dispatchers (lazy imports so --help needs nothing) ----------


def _cmd_init(args: Any) -> int:
    from .init_cmd import run_init

    return run_init(env_file=args.env_file, force=args.force)


def _cmd_doctor(args: Any) -> int:
    from .doctor import run_doctor

    return run_doctor()


def _cmd_brief(args: Any) -> int:
    from .brief_cmd import run_brief

    return run_brief(post=args.post)


def _cmd_run(args: Any) -> int:
    from .run_cmd import run_run

    return run_run(no_checks=args.no_checks)


def _cmd_coming_soon(args: Any) -> int:
    print(
        f"aidedecamp {args.group}: coming with roadmap milestone M4 "
        f"(docs/roadmap.md — prompts 11/12)."
    )
    return 0
