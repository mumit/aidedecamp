# aidedecamp

A self-learning workspace assistant over Gmail, Calendar, Google Chat, and Slack,
running on Fuel iX and reachable by text and voice.

This is the application package. The generic Fuel iX transport lives in the
sibling [`bearer-openai`](../bearer-openai) package.

See [`../../docs/design.md`](../../docs/design.md) for the full architecture,
memory design, autonomy model, and roadmap.

## Layout

```
src/aidedecamp/
  fuelix.py       Fuel iX base URL, verified model IDs, task-shape routing
  config/         per-deployment settings (personal vs TELUS) from env
  orchestrator/   LangGraph graphs + the autonomy ladder / permission matrix
  memory/         capture / consolidate / retrieve (Mem0 -> Graphiti)
  connectors/     swappable Workspace access (MCP or direct OAuth) + Slack
  ingestion/      Gmail push, Calendar webhook, Chat events, Slack socket
  channels/       Slack, Google Chat, browser, voice
  audit/          structured reason-for-action log
```

Only `fuelix.py`, `config/`, and `orchestrator/autonomy.py` carry real logic
today; the rest are documented stubs to be filled in per the roadmap.

## Status

Phase 0, in progress. Done: Fuel iX client + routing, config, autonomy matrix.
Next: LangGraph orchestrator skeleton, then Mem0, then Slack + Gmail read-only
for the v0 morning brief.

## License

MIT
