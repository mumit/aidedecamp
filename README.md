# Aide-de-camp

A self-learning workspace assistant over Gmail, Calendar, Google Chat, and Slack,
running on [Fuel iX](https://fuelix.ai), reachable by text and voice. It gets
better at being *your* assistant over time: it learns your preferences from the
edits you make to its drafts, remembers who and what your projects are about, and
earns autonomy one narrow, reversible action at a time rather than being handed
it up front.

Read [`docs/design.md`](docs/design.md) first — it's the source of truth for the
architecture, the memory model, the earned-autonomy ladder, and the phased
roadmap. [`docs/decisions.md`](docs/decisions.md) is a running log of settled
architectural decisions and the reasoning behind them.
[`docs/deployment.md`](docs/deployment.md) covers the concrete GCP setup for
running it.

## Why a monorepo with two packages

```
packages/
  bearer-openai/   Generic, vendor-neutral OpenAI-compatible client for
                   bearer-token gateways. No Fuel iX (or any vendor) specifics.
                   Independently publishable and reusable by anyone behind such
                   a gateway. Intended to be split into its own repo later.

  aidedecamp/      The assistant itself. Depends on bearer-openai. Carries all
                   the Fuel iX config, orchestration, memory, connectors, and
                   channels.
```

The two are developed together now for convenience; `bearer-openai` deliberately
knows nothing about `aidedecamp` so it can leave home cleanly.

## Quickstart — first brief in about 15 minutes

Prerequisites: Python 3.10+, Docker, a Google account, and a Fuel iX bearer
token. The default **poll mode** needs no GCP project, no Pub/Sub, and no
webhook infrastructure — everything is outbound-only.

```bash
# 1. Clone and install
git clone <this repo> && cd aidedecamp
python -m venv .venv && source .venv/bin/activate
pip install -e "packages/bearer-openai" \
            -e "packages/aidedecamp[orchestrator,memory,google,slack]"

# 2. Start the memory substrate (Qdrant; Mem0 runs in-process)
docker compose -f packages/aidedecamp/deploy/compose.yml up -d

# 3. Interactive setup — writes .env, can run the Google OAuth consent flow
aidedecamp init

# 4. Validate everything, then see your first brief in the terminal
aidedecamp doctor
aidedecamp brief
```

Make it always-on with `aidedecamp run` (a terminal, tmux, or the systemd
unit in [`docs/deployment.md`](docs/deployment.md)) — or fully containerized:

```bash
docker compose -f packages/aidedecamp/deploy/compose.yml --profile assistant up -d --build
```

From there it polls your inbox, posts a morning brief at your configured
time, and sends draft-approval cards to Slack/Chat; approving one creates
the draft in Gmail for you to send. Never commit `.env`.

### Dev setup

```bash
pip install -e "packages/bearer-openai[dev]" -e "packages/aidedecamp[dev]"
pytest packages/aidedecamp packages/bearer-openai
```

Optional extras (the package imports without them): `[memory]` (Mem0 +
Qdrant), `[orchestrator]` (LangGraph), `[slack]` (Slack Bolt), `[google]`
(direct-OAuth Google API access + Pub/Sub).

`packages/aidedecamp/deploy/` holds standalone deployable infrastructure —
the compose stack, the assistant Dockerfile, and the Calendar-webhook/
Chat-interaction republisher service — each with its own dependency set, not
part of the main test run (see `pytest.ini`'s `norecursedirs`).

## Running it for real

Poll mode (above) is the day-one path. The hardened production posture —
Pub/Sub push ingestion, the republisher on Cloud Run, Secret Manager, a
dedicated GCP project per deployment — is Track B in
[`docs/deployment.md`](docs/deployment.md), for both a personal and a
TELUS-style deployment. `aidedecamp doctor` tells you what's missing at
each step.

## Status

Read-only + rung-2 (propose, wait for approval) is built end to end: Fuel iX
client and task-shape model routing, per-deployment config, the autonomy
permission matrix, LangGraph draft-and-approve orchestration, Mem0-backed
memory (capture/consolidate/retrieve), triage (urgent/routine/noise), Gmail +
Calendar + Google Chat + Slack ingestion and channels, Calendar
scheduling-conflict detection (read-only), the structured audit log, and the
`runtime.py` entrypoint that wires all of it into one process. 312 tests,
all offline (no live credentials or network calls required to run the suite).

What's deliberately not built: a Calendar write-action layer (creating holds,
responding to invites — no well-defined trigger yet, and it needs its own
autonomy-ladder decision), and an actual live deployment (nothing has run
against a real GCP project yet). See `CLAUDE.md`'s "Next steps" and "Still
open" sections for the current, maintained list.

## Security posture (read before running anything that touches real data)

This project is, by construction, the exact shape the OpenClaw incidents warned
about: a privileged agent exposed to untrusted input (any email you receive) with
the ability to act. The design defends against that deliberately — see
`docs/design.md` §3.2 and §8. Rules that are non-negotiable from day one (the
full list is in `CLAUDE.md`):

- Untrusted content (email/chat bodies) is tagged as untrusted before it
  reaches the model — never framed as instructions.
- Autonomy is scoped per `(action, domain)`, never global, and fails safe to
  human approval.
- Send is refused by default; enabling it is a deliberate, separately-reviewed
  change.
- No inbound port on the credential-holding process — ingestion is
  pull/outbound (Pub/Sub, Slack Socket Mode); the two sources needing a real
  webhook (Calendar, Chat card-interactions) go through a separate,
  credential-free republisher service that only forwards to Pub/Sub.

Do not short-circuit any of these to make something "work."

## License

MIT — see [`LICENSE`](LICENSE).
