"""Aide-de-camp: a self-learning workspace assistant over Gmail, Calendar,
Google Chat, and Slack, running on Fuel iX.

See docs/design.md for the full architecture, and the module docstrings below
for where each part of that design lives:

    config/       runtime configuration (per-deployment: personal vs TELUS)
    fuelix.py     Fuel iX base URL, model IDs, and task-shape model routing
    orchestrator/ LangGraph graphs (triage, draft-and-approve, schedule, brief)
    memory/       capture / consolidate / retrieve over Mem0 (-> Graphiti later)
    connectors/   swappable Workspace access (MCP or direct OAuth) + Slack
    ingestion/    event sources (Gmail push, Calendar webhook, Chat, Slack)
    channels/     interaction surfaces (Slack, Chat, browser, voice)
    audit/        structured reason-for-action log (XAI, from day one)
"""

__version__ = "0.0.1"
