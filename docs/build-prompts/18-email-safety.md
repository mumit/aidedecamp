# 18 — Email-safe ingestion + correct reply envelope

**Milestone:** M6 stabilization · **Fixes review finding #3 (P0)**

---

Read `CLAUDE.md`, `docs/decisions.md`, and the M6 section of
`docs/roadmap.md`. Run `pytest` before and after.

## Problem

Two related envelope bugs:

1. **Ingestion reacts to the owner's own mail.** `gmail_history` collects
   every `messagesAdded` record with no label filtering — sending a mail or
   saving a draft triggers triage and can produce a "reply" to yourself.
2. **Reply targeting uses the FIRST message's sender.** `EmailThread` mixes
   first-message From/subject with last-message body, and the apply node
   addresses `create_draft` to `thread.from_addr`. For M5 follow-ups —
   threads the owner started, by definition — the follow-up draft is
   addressed BACK TO THE OWNER. `Reply-To` is ignored entirely.

## Task

1. **Label filtering**: in `gmail_history`, skip messagesAdded whose
   `labelIds` include `SENT` or `DRAFT`; a thread only counts as changed if
   at least one non-SENT/DRAFT message was added.
2. **Envelope fields**: `EmailThread` gains `reply_to: str = ""` — the
   correct reply target: the newest message NOT authored by the owner,
   preferring its `Reply-To` header over `From`. `DirectOAuthConnector`
   gains `owner_email` (bound from `settings.user_id` in `make_connector`
   when it's a real address) so the thread builders can walk messages
   newest-first and pick the counterparty. MCP maps a loose `reply_to` key.
   No counterparty in the thread → `reply_to` stays empty.
3. **Apply targeting**: `make_connector_apply_fn` gains `owner_email`;
   recipient = `thread.reply_to or thread.last_from_addr or
   thread.from_addr`, and **if the resolved recipient is the owner (or
   empty), apply refuses** — `applied_ref=None` with an audit-visible
   reason; the confirmation says nothing was created and why. Never draft
   to yourself.
4. **Follow-up candidates require a counterparty**: `find_nudge_candidates`
   drops threads whose `reply_to` is empty/owner (an owner-only sent thread
   has nobody to nudge).

## Constraints

- Filtering happens at ingestion (cheapest point); triage remains a pure
  gate. No new write actions.
- Both connectors implement the new fields; provenance tagging unchanged.

## Acceptance

- Tests: SENT/DRAFT-only history records produce no changed threads (mixed
  records still count); reply_to = newest non-owner sender's Reply-To, then
  From; apply addresses reply_to and refuses owner/empty recipients with an
  honest confirmation; follow-up candidates skip counterparty-less threads;
  regression: normal inbound reply flow addresses the counterparty even
  when the owner sent the thread's first message.
- decisions.md entry + CLAUDE.md touch-ups.
