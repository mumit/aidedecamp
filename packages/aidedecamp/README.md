# aidedecamp

A self-learning workspace assistant over Gmail, Calendar, Google Chat, and Slack,
running on Fuel iX and reachable by text and voice.

This is the application package. The generic Fuel iX transport lives in the
sibling [`bearer-openai`](../bearer-openai) package.

See [`../../docs/design.md`](../../docs/design.md) for the full architecture,
memory design, autonomy model, and roadmap;
[`../../docs/decisions.md`](../../docs/decisions.md) for the settled
architectural decisions and why; and
[`../../docs/deployment.md`](../../docs/deployment.md) for how to actually run
this against a live GCP project.

## Layout

```
src/aidedecamp/
  fuelix.py       Fuel iX base URL, verified model IDs, task-shape routing
  config/         per-deployment settings (personal vs TELUS) from env
  credentials.py  Google credential loading (service account / OAuth user / ADC)
  orchestrator/   LangGraph draft-and-approve graph, autonomy permission matrix,
                  triage (plain fn, Task.CLASSIFY), scheduling conflict detection
                  (plain fn), the shared resume_workflow() Command(resume=...)
  memory/         substrate-agnostic MemoryStore, Mem0 impl, capture signals
  connectors/     swappable Workspace access: managed MCP or direct OAuth
  ingestion/      Gmail watch/history, Calendar watch/sync, Chat Workspace
                  Events + card-interaction decoding
  dispatcher.py   the routing seam: notification/event -> graph invocation,
                  conflict-check, or brief/converse reply
  channels/       Slack (Socket Mode) + Google Chat (Cards v2) — thin doors,
                  no assistant logic
  brief.py        read-only morning brief (plain fn, no HITL need)
  app.py          build_app() -> AppContext (graph + memory + client + audit log)
  runtime.py      build_runtime() -> Runtime, the always-on entrypoint
  audit/          structured, queryable reason-for-action log (JsonlAuditLog)

deploy/
  mem0-compose.yml   local Qdrant + Mem0 for the memory substrate
  republisher/       standalone Cloud Run service (own deps, own tests) —
                     the two webhook exceptions to "no inbound port": Calendar
                     push notifications and Chat card-interactions
```

## Status

Read-only and rung-2 (propose, wait for human approval) are built end to end
and tested (offline — no live credentials needed to run the suite): Fuel iX
routing, per-deployment config, the autonomy matrix, the LangGraph
draft-and-approve graph, Mem0-backed memory, triage, Gmail + Calendar + Google
Chat + Slack ingestion and channels (including Slack conversational Q&A and
Google Chat's async card-interaction flow), Calendar scheduling-conflict
detection (read-only by design), the audit log, and `runtime.py` wiring
everything into one process.

Not built, deliberately: a Calendar write-action layer (no well-defined
trigger yet, needs its own autonomy-ladder decision) and an actual live
deployment (nothing has run against a real GCP project yet — see
`../../docs/deployment.md`). See `../../CLAUDE.md`'s "Next steps" for the
current, maintained list.

## License

MIT
