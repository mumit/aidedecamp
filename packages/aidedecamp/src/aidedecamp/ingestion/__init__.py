"""Event ingestion (design doc 4.3, 4.6).

Gmail: users.watch -> Cloud Pub/Sub pointer -> users.history.list. Watch expires
every 7 days; renew daily. Calendar: registered HTTPS webhook (no Pub/Sub) — keep
it off the credential-holding box via a thin Cloud Run/Function republisher onto
Pub/Sub. Chat: Workspace Events API (Pub/Sub delivery). Slack: Socket Mode
(outbound only). Net goal: the box holding credentials/memory has no open inbound
port (the OpenClaw lesson, 8.1).

CRITICAL: tag every ingested payload with provenance (user-authored vs
fetched-from-email/chat) before it reaches the model. Untrusted content must be
marked untrusted — this is the concrete defense against indirect prompt injection.
"""
