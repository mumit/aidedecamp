# Aide-de-camp

A self-learning workspace assistant over Gmail, Calendar, Google Chat, and Slack,
running on [Fuel iX](https://fuelix.ai), reachable by text and voice. It gets
better at being *your* assistant over time: it learns your preferences from the
edits you make to its drafts, remembers who and what your projects are about, and
earns autonomy one narrow, reversible action at a time rather than being handed
it up front.

Read [`docs/design.md`](docs/design.md) first — it's the source of truth for the
architecture, the memory model, the earned-autonomy ladder, and the phased
roadmap.

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

## Quick start (dev)

```bash
# from the repo root
python -m venv .venv && source .venv/bin/activate
pip install -e "packages/bearer-openai[dev]"
pip install -e "packages/aidedecamp[dev]"
pytest
```

Then copy `.env.example` to `.env` and fill in your Fuel iX token and, as you
wire up later phases, your Slack/Google credentials. Never commit `.env`.

## Status

Phase 0 in progress. See each package's README and `docs/design.md` §6 for the
roadmap. Current: Fuel iX client + task routing, per-deployment config, and the
autonomy permission matrix are built and tested.

## Security posture (read before running anything that touches real data)

This project is, by construction, the exact shape the OpenClaw incidents warned
about: a privileged agent exposed to untrusted input (any email you receive) with
the ability to act. The design defends against that deliberately — see
`docs/design.md` §3.2 and §8. Two rules that are non-negotiable from day one:
untrusted content (email/chat bodies) is tagged as untrusted before it reaches
the model, and autonomy is scoped per (action, domain), never global. Do not
short-circuit either.

## License

MIT — see [`LICENSE`](LICENSE).
