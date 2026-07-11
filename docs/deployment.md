# Deployment Guide — GCP (personal and TELUS)

This is the concrete "how to actually run this" companion to `docs/design.md`
(architecture) and `docs/decisions.md` (why things are shaped the way they
are). Read `CLAUDE.md`'s non-negotiable rules first — this guide implements
them, it doesn't relitigate them.

**Status: unexercised.** Every step below is derived from the code and from
Google's documented APIs, but nothing here has been run against a real GCP
project yet. Treat this as a detailed first draft to execute and correct
against reality, not a verified runbook. Update it as you go — a deployment
guide that drifts from what actually works is worse than none.

**Change from `docs/design.md` §4.6**: that section assumed personal ran on a
home server and only TELUS ran on GCP. Both deployments now run on GCP —
personal and TELUS each get their own **separate GCP project**, keeping the
"two fully separate deployments, same codebase" property design 4.6 wanted,
just with cloud infrastructure on both sides instead of one home server + one
VM. This is a decision, not a code change; see `docs/decisions.md`.

---

## 1. Shape of one deployment

Each deployment (personal, TELUS) is:

- **One GCP project**, isolated from the other deployment's project. No
  shared Pub/Sub topics, no shared service accounts, no shared anything.
- **One Compute Engine VM** running `python -m aidedecamp` (via systemd) plus
  a local Qdrant container for memory (`deploy/mem0-compose.yml`).
- **One thin, stateless Cloud Run service** — the Calendar webhook
  republisher (the one source needing a real inbound HTTPS endpoint; rule 5
  keeps that off the VM). Gmail and Chat don't need this — they deliver via
  Pub/Sub directly.
- **Secret Manager** for `FUELIX_TOKEN`, Google OAuth credentials, and Slack
  tokens.
- **Pub/Sub topics + subscriptions** for Gmail, Chat, and (indirectly, via
  the republisher) Calendar.

Run every step in this guide **twice**, once per GCP project, with
deployment-specific values substituted (project id, Slack workspace, Chat
space, calendar owner). Nothing here is shared between the two.

---

## 2. Prerequisites

- A GCP project per deployment, billing enabled. (`gcloud projects create
  aidedecamp-personal` / `aidedecamp-telus` or equivalent — TELUS's project
  will likely go through TELUS's own project-creation process, not a
  personal `gcloud` login.)
- `gcloud` CLI authenticated against the right account for each project.
- A Fuel iX bearer token (`FUELIX_TOKEN`) for whichever gateway this
  deployment talks to.
- For TELUS: sign-off from TELUS IT on whichever `ConnectorMode` you end up
  needing (`mcp` vs `direct_oauth`) and on the OAuth scopes below — this is
  the governance step design 4.7 flagged; don't skip it and don't assume it's
  a formality.
- A Slack workspace (if using the Slack channel) where you can install an
  app, and/or a Google Chat space (if using the Chat channel).

Set the active project for the rest of this guide:

```bash
export PROJECT_ID=aidedecamp-personal   # or aidedecamp-telus
gcloud config set project "$PROJECT_ID"
```

---

## 3. Enable APIs

```bash
gcloud services enable \
  gmail.googleapis.com \
  calendar-json.googleapis.com \
  chat.googleapis.com \
  workspaceevents.googleapis.com \
  pubsub.googleapis.com \
  secretmanager.googleapis.com \
  compute.googleapis.com \
  run.googleapis.com \
  iam.googleapis.com
```

`workspaceevents.googleapis.com` is what backs Chat's proactive message
ingestion (`ingestion/chat_events.py`); `chat.googleapis.com` backs the Cards
v2 send/receive path (`channels/gchat.py`).

---

## 4. Google credentials — the one genuinely different step per deployment

This is the step most likely to trip you up, because **personal Gmail and a
TELUS Workspace account need different credential types**, and
`credentials.py` supports both, but you have to pick correctly.

### Personal (consumer Gmail account)

Consumer Gmail has no domain-wide delegation — a service account cannot be
granted access to a personal `@gmail.com` inbox. You need a real **OAuth user
credential**: a one-time human authorization that produces a refresh token.

1. GCP Console → APIs & Services → OAuth consent screen. External, testing
   mode is fine for a single-user personal deployment.
2. Create an OAuth 2.0 Client ID (type: Desktop app, simplest for a one-time
   local authorization flow).
3. Run the authorization flow once (`google-auth-oauthlib`'s
   `InstalledAppFlow`, or any standard OAuth helper script) against the
   scopes in `credentials.py::SCOPES_DEFAULT`, producing a JSON file shaped
   like:
   ```json
   {"type": "authorized_user", "client_id": "...", "client_secret": "...", "refresh_token": "..."}
   ```
   (`credentials.py` detects this via the absence of `"type":
   "service_account"` and loads it through
   `google.oauth2.credentials.Credentials.from_authorized_user_info`.)
4. Store that JSON in Secret Manager (§6), never in the repo or on local disk
   outside the secrets flow.

### TELUS (Workspace account)

Two paths, depending on what TELUS IT approves:

- **Domain-wide delegation (preferred if approved)**: create a service
  account, grant it domain-wide delegation in the Workspace Admin console for
  exactly `SCOPES_DEFAULT`, and configure it to impersonate the specific
  mailbox this deployment acts as. With this, the VM's attached service
  account identity can resolve credentials via
  `google.auth.default()` directly — no credentials file needed at all,
  `google_credentials_file` stays unset.
- **Per-user OAuth (if domain-wide delegation is refused)**: same flow as
  personal above, just against the TELUS Workspace account instead of a
  personal Gmail account. This is exactly why `connectors/base.py`'s
  interface and `ConnectorMode` exist as a config choice — a TELUS "no" on
  one auth path is a config change, not a redesign.

Either way, confirm the actual scope list against current Google docs before
requesting it — `SCOPES_DEFAULT` in `credentials.py` is:

```
gmail.readonly, gmail.compose, calendar.readonly, chat.messages, chat.spaces.readonly
```

`gmail.send` is deliberately **not** in this list (rule 4 — send is refused
structurally; only add it as a separate, reviewed change alongside
`send_enabled=True` and an autonomy grant).

---

## 5. Service account for the VM itself

Separate from the Gmail/Calendar/Chat credential above: the Compute Engine
VM needs its own service account with least-privilege IAM, per design 4.6:

```bash
gcloud iam service-accounts create aidedecamp-runtime \
  --display-name="Aide-de-camp runtime"

# Pub/Sub: pull from subscriptions, nothing else
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:aidedecamp-runtime@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/pubsub.subscriber"

# Secret Manager: read secrets, nothing else
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:aidedecamp-runtime@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

If using domain-wide delegation for TELUS (§4), this is also the service
account you grant delegation to — one identity, not two.

---

## 6. Secrets

```bash
printf '%s' "$FUELIX_TOKEN_VALUE" | gcloud secrets create fuelix-token --data-file=-
printf '%s' "$SLACK_BOT_TOKEN_VALUE" | gcloud secrets create slack-bot-token --data-file=-
printf '%s' "$SLACK_APP_TOKEN_VALUE" | gcloud secrets create slack-app-token --data-file=-
gcloud secrets create google-credentials --data-file=./oauth-credentials.json
```

Grant the runtime service account access to each (`secretAccessor` role,
already granted at project level above — narrow to per-secret bindings if you
want tighter scoping).

At VM startup, secrets are pulled and written to a local path (or exported as
env vars) by the startup script — see §10. Rotating the Fuel iX token is then
`gcloud secrets versions add fuelix-token --data-file=-` plus a service
restart, matching the workflow `CLAUDE.md` rule 6 describes.

---

## 7. Pub/Sub topics and subscriptions

Three ingestion paths, three topic/subscription pairs. Gmail and Chat publish
directly to their topic (Google's own watch/subscribe APIs do this); Calendar
has no such option, so its topic is published to by the thin republisher
(§8), not by Google directly.

```bash
for name in gmail chat calendar; do
  gcloud pubsub topics create "aidedecamp-${name}"
  gcloud pubsub subscriptions create "aidedecamp-${name}-sub" \
    --topic="aidedecamp-${name}" \
    --ack-deadline=60
done
```

Grant Gmail's own service account publish rights on its topic (Google
requires this explicitly — `gmail-api-push@system.gserviceaccount.com`):

```bash
gcloud pubsub topics add-iam-policy-binding aidedecamp-gmail \
  --member="serviceAccount:gmail-api-push@system.gserviceaccount.com" \
  --role="roles/pubsub.publisher"
```

Map these to config:

| Topic | Env var |
|---|---|
| `aidedecamp-gmail` | `ADC_GMAIL_PUBSUB_TOPIC` |
| `aidedecamp-gmail-sub` | `ADC_GMAIL_PUBSUB_SUBSCRIPTION` |
| `aidedecamp-chat` | `ADC_CHAT_PUBSUB_TOPIC` |
| `aidedecamp-chat-sub` | `ADC_CHAT_PUBSUB_SUBSCRIPTION` |
| `aidedecamp-calendar` | `ADC_CALENDAR_PUBSUB_TOPIC` |
| `aidedecamp-calendar-sub` | `ADC_CALENDAR_PUBSUB_SUBSCRIPTION` |

---

## 8. The Calendar webhook republisher (Cloud Run)

Calendar push notifications are the one source Google only delivers via a
direct HTTPS POST (no Pub/Sub option) — design 4.6's flagged exception, and
the reason rule 5 needs a hop here instead of a flat "no webhooks anywhere."
This service is intentionally tiny and stateless: validate the notification
headers, republish onto the `aidedecamp-calendar` topic, return 200. It never
touches credentials, memory, or the Fuel iX token — if it's compromised, it
can at most inject a bogus (headers-only) message onto one Pub/Sub topic that
`Runtime.process_calendar_notification` just re-reconciles from, safely.

**Not part of the installable `aidedecamp` package** — it lives at
`packages/aidedecamp/deploy/calendar_republisher/` (own `main.py`,
`requirements.txt`, `Dockerfile`, `test_main.py`), deployed independently,
the same way `deploy/mem0-compose.yml` is infrastructure rather than
application code. It's a small Flask app with one route:

1. Accept a POST, read the `X-Goog-Channel-ID` / `X-Goog-Resource-ID` /
   `X-Goog-Resource-State` / `X-Goog-Message-Number` headers (the exact shape
   `ingestion/calendar_sync.py::decode_calendar_headers` expects as input).
2. Publish `{"channel_id": ..., "resource_id": ..., "resource_state": ...,
   "message_number": ...}` as JSON onto `aidedecamp-calendar`, waiting for
   publish confirmation (`future.result()`) before acking — losing a
   notification because we returned 200 before the publish actually landed
   would be worse than the extra latency of waiting for it.
3. Return HTTP 200.

Test it (own dependency set, not part of the main `pytest` run):

```bash
cd packages/aidedecamp/deploy/calendar_republisher
pip install -r requirements.txt pytest
pytest test_main.py
```

Deploy it, note its HTTPS URL, and set that as `ADC_CALENDAR_WEBHOOK_ADDRESS`
— that's the `address` field `ensure_calendar_watch` registers with Google.

```bash
gcloud run deploy aidedecamp-calendar-republisher \
  --source=packages/aidedecamp/deploy/calendar_republisher \
  --set-env-vars="CALENDAR_PUBSUB_TOPIC=projects/${PROJECT_ID}/topics/aidedecamp-calendar" \
  --allow-unauthenticated \
  --region=us-central1
```

(`--allow-unauthenticated` because Google's webhook caller isn't a GCP
identity you can IAM-gate the usual way; validate via the channel token
Google echoes back instead, if you want request authenticity checking beyond
"this hit our known URL.")

---

## 9. Compute Engine VM

A small VM is enough (design 4.6): `e2-small` or `e2-medium` runs the app
process and a local Qdrant container comfortably.

```bash
gcloud compute instances create aidedecamp-vm \
  --machine-type=e2-medium \
  --service-account="aidedecamp-runtime@${PROJECT_ID}.iam.gserviceaccount.com" \
  --scopes=cloud-platform \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=20GB
```

On the VM:

```bash
sudo apt-get update && sudo apt-get install -y python3.11 python3.11-venv docker.io docker-compose-plugin git

git clone <this-repo> /opt/aidedecamp
cd /opt/aidedecamp

python3.11 -m venv .venv
source .venv/bin/activate
pip install -e "packages/bearer-openai[dev]"
pip install -e "packages/aidedecamp[dev,memory,orchestrator,slack,google]"

# Memory substrate (Qdrant)
docker compose -f packages/aidedecamp/deploy/mem0-compose.yml up -d
```

Pull secrets into environment at boot (a startup script, not committed env
files):

```bash
export FUELIX_TOKEN=$(gcloud secrets versions access latest --secret=fuelix-token)
export SLACK_BOT_TOKEN=$(gcloud secrets versions access latest --secret=slack-bot-token)
export SLACK_APP_TOKEN=$(gcloud secrets versions access latest --secret=slack-app-token)
gcloud secrets versions access latest --secret=google-credentials > /opt/aidedecamp/google-credentials.json
```

---

## 10. Environment variables — full reference

Set these (directly, or via the secret-pull script above feeding a
`systemd` `EnvironmentFile`). Grouped by what they configure; `ADC_*` prefix
is this project's own convention, distinct from Google's own env vars.

**Core / identity**
```
ADC_DEPLOYMENT=personal              # or telus
ADC_CONNECTOR_MODE=direct_oauth      # or mcp, per §4's decision
ADC_USER_ID=me                       # or an explicit email; also the Gmail API "me" alias
FUELIX_TOKEN=<from Secret Manager>
```

**Memory**
```
ADC_MEM0_URL=http://localhost:8000   # only used if running the standalone Mem0 server; the
                                      # in-process library path (default) talks to Qdrant directly
```

**Audit + state (persisted to local disk on the boot persistent disk — back
this directory up, it's the only copy)**
```
ADC_AUDIT_LOG_PATH=/opt/aidedecamp/data/audit.log.jsonl
ADC_DB_PATH=/opt/aidedecamp/data/aidedecamp.db
ADC_GMAIL_WATCH_STATE_PATH=/opt/aidedecamp/data/gmail_watch_state.json
ADC_CHAT_SUBSCRIPTION_STATE_PATH=/opt/aidedecamp/data/chat_subscription_state.json
ADC_CALENDAR_WATCH_STATE_PATH=/opt/aidedecamp/data/calendar_watch_state.json
ADC_CALENDAR_SYNC_STATE_PATH=/opt/aidedecamp/data/calendar_sync_state.json
```

**Google credentials**
```
ADC_GOOGLE_CREDENTIALS_FILE=/opt/aidedecamp/google-credentials.json
# Omit entirely for TELUS-with-domain-wide-delegation — ADC via the VM's
# service account resolves it instead (§4).
GOOGLE_PROJECT_ID=<project id>
```

**Gmail / Chat / Calendar ingestion**
```
ADC_GMAIL_PUBSUB_TOPIC=projects/<project>/topics/aidedecamp-gmail
ADC_GMAIL_PUBSUB_SUBSCRIPTION=projects/<project>/subscriptions/aidedecamp-gmail-sub
ADC_CHAT_PUBSUB_TOPIC=projects/<project>/topics/aidedecamp-chat
ADC_CHAT_PUBSUB_SUBSCRIPTION=projects/<project>/subscriptions/aidedecamp-chat-sub
ADC_CALENDAR_PUBSUB_TOPIC=projects/<project>/topics/aidedecamp-calendar
ADC_CALENDAR_PUBSUB_SUBSCRIPTION=projects/<project>/subscriptions/aidedecamp-calendar-sub
ADC_CALENDAR_WEBHOOK_ADDRESS=https://aidedecamp-calendar-republisher-xxxxx.run.app
ADC_CALENDAR_ID=primary
```

**Channels**
```
SLACK_APP_TOKEN=<from Secret Manager>       # xapp-...
SLACK_BOT_TOKEN=<from Secret Manager>       # xoxb-...
ADC_SLACK_CHANNEL=C0123456789               # where briefs/approvals post proactively
ADC_CHAT_SPACE=spaces/AAAAxxxxxxx           # where Chat briefs/approvals post proactively
```

Leave `ADC_SLACK_CHANNEL`/`ADC_CHAT_SPACE` unset to run without that
channel's proactive posting — `build_runtime()` only constructs a channel
when its config is present (see `runtime.py`).

---

## 11. Slack app setup

1. https://api.slack.com/apps → Create New App → From scratch.
2. **Socket Mode**: enable it, generate an app-level token with the
   `connections:write` scope → this is `SLACK_APP_TOKEN`.
3. **OAuth & Permissions** → Bot Token Scopes: `chat:write`, `im:history`,
   `im:read`, `im:write` (for `message.im` DMs — `channels/slack.py`'s
   conversational handler), plus whatever's needed for the approval buttons
   (`chat:write` covers posting blocks). Install to workspace → this produces
   `SLACK_BOT_TOKEN`.
4. **Event Subscriptions** → Subscribe to bot events → `message.im` (matches
   the filter in `channels/slack.py`'s registered handler).
5. **Interactivity & Shortcuts**: enable it (Socket Mode delivers these too;
   no Request URL needed).
6. Invite the bot to `ADC_SLACK_CHANNEL` if it's a channel (not needed for
   DMs).

---

## 12. Google Chat app setup

1. GCP Console → APIs & Services → Google Chat API → Configuration.
2. App name, avatar, description. Interactive features: **on**.
3. Connection settings: since this is Socket-Mode-equivalent for Chat isn't a
   thing — Chat's card-click events need an HTTP endpoint. Point it at a
   thin endpoint (can be the same Cloud Run service as the Calendar
   republisher, or a second small one) that calls
   `GoogleChatChannel.handle_interaction(event)` and returns its result as
   the HTTP response body. This endpoint receives interaction events only
   (button clicks) — it is not the credential-holding process, matching the
   design's transport contract (`docs/decisions.md`, "Google Chat channel").
4. Permissions: whichever spaces/users should be able to add the app.
5. Note the space id (`spaces/AAAAxxxxxxx`) for `ADC_CHAT_SPACE` — get it via
   the Chat API (`spaces.list`) or from the space's URL once the app is
   added to it.

---

## 13. First-run bootstrap

Before starting the long-running process, register the watches/subscriptions
once (idempotent — safe to re-run):

```python
from aidedecamp.runtime import build_runtime

rt = build_runtime()
rt.renew_gmail_watch(force=True)
rt.renew_chat_subscription(force=True)   # only if ADC_CHAT_SPACE is set
rt.renew_calendar_watch(force=True)      # only if ADC_CALENDAR_WEBHOOK_ADDRESS is set
```

Schedule this to re-run daily (systemd timer or cron calling a tiny wrapper
script) — Gmail/Chat/Calendar watches all expire and `ensure_*` renews
proactively at <48h remaining, but only if something actually calls it on a
schedule. This confirms `docs/decisions.md`'s existing note: missing this
step is the single most common way this class of integration silently goes
quiet.

---

## 14. Running the process

`systemd` unit (`/etc/systemd/system/aidedecamp.service`):

```ini
[Unit]
Description=Aide-de-camp
After=network.target docker.service

[Service]
Type=simple
WorkingDirectory=/opt/aidedecamp
EnvironmentFile=/opt/aidedecamp/aidedecamp.env
ExecStart=/opt/aidedecamp/.venv/bin/python -m aidedecamp
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now aidedecamp
journalctl -u aidedecamp -f    # tail logs
```

`__main__.py` calls `build_runtime().run()`, which starts the Gmail/Chat/
Calendar Pub/Sub pull loops on daemon threads and blocks the main thread on
Slack's Socket Mode connection (or just waits, if Slack isn't configured) —
see `runtime.py`'s docstring.

---

## 15. Verifying the deployment

Rough end-to-end smoke test, in order:

1. `journalctl -u aidedecamp -f` shows the process started without raising
   (a missing/invalid secret or scope typically fails loudly at `build_app`/
   `build_runtime` construction time).
2. Send yourself a test email → confirm a Pub/Sub message lands (`gcloud
   pubsub subscriptions pull aidedecamp-gmail-sub --auto-ack`) and a draft
   approval card appears in Slack/Chat within the pull loop's poll window.
3. DM the Slack bot / message the Chat space with something conversational →
   confirm a reply comes back via `_converse`.
4. Ask for "the morning brief" in either channel → confirm `assemble_brief`
   output comes back.
5. Create two overlapping calendar holds → confirm the republisher fires,
   the Pub/Sub message lands on `aidedecamp-calendar-sub`, and a conflict
   notification posts (`dispatcher.handle_calendar_notification`).
6. Approve a drafted reply → confirm the capture-signal write lands in Mem0
   (`memory/signals.py`), and that the audit log
   (`ADC_AUDIT_LOG_PATH`) has a matching `draft_approve` entry.

---

## 16. Ongoing maintenance

- **Watch/subscription renewal**: the daily cron/timer from §13. Missing this
  is silent — no error, ingestion just stops.
- **Secret rotation**: `gcloud secrets versions add <name> --data-file=-` +
  `systemctl restart aidedecamp`. `FUELIX_TOKEN` specifically: a 401 raises
  `TokenRejectedError` in logs rather than retrying — that's your signal to
  rotate, not a bug to work around (rule 6).
- **Google's agent-tool quota/tiering** (`CLAUDE.md`'s "Still open"): confirm
  the actual watch-renewal + pull cadence here against current Google quota
  docs before relying on this in daily use — this was flagged as unverified
  during design and hasn't been checked against a real deployment yet.
- **Disk backup**: `ADC_DB_PATH` (LangGraph checkpoints), the four
  `*_STATE_PATH` files, and the audit log are the only copies of this
  deployment's state — back up the VM's data directory, not just the code.

---

## 17. Cost shape (rough, personal-scale usage)

- e2-medium VM: ~$25-30/mo running continuously.
- Cloud Run republisher: effectively free at personal-mailbox volume
  (occasional invocations, well within the free tier).
- Pub/Sub: free tier covers personal-scale message volume comfortably.
- Secret Manager: a few cents/month for a handful of secrets.
- Fuel iX usage: billed separately per the gateway's own terms, not GCP.

TELUS-scale volume (a busier mailbox, more calendar churn) may cross free
tiers on Pub/Sub/Cloud Run — check actual usage after a week or two rather
than pre-optimizing.
