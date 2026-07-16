# Hosted customer export boundary

This document defines the security and product contract for Attune-hosted
customer exports. An `export_jobs` row, bucket, or download button alone does
not constitute a working export.

## Customer journey

1. A signed-in owner chooses one server-defined scope: account and preferences,
   conversations, memories, or customer-visible activity. The page describes
   what is and is not included.
2. Attune requires a fresh web authentication and an exact confirmation. The
   browser supplies neither tenant identity, table names, object paths, nor
   retention duration.
3. The request page shows queued, generating, ready, failed, or expired. It does
   not expose internal errors, object identifiers, wrapping keys, or signed
   storage URLs.
4. When ready, the owner reauthenticates and downloads once through Attune.
   Attune streams the object with an attachment filename and no-store headers.
5. The object becomes unavailable immediately after the first successful
   download or after 24 hours, whichever occurs first. The owner may explicitly
   erase it sooner.

Google and Slack remain the source of truth for data Attune did not retain.
Attune does not silently refetch an entire mailbox, calendar, or channel to
manufacture an account export.

## Fixed scopes and exclusions

| Scope | Included | Always excluded |
| --- | --- | --- |
| `account` | tenant/principal profile, installations, connector metadata, policy, autonomy, onboarding, and channel preferences/destinations | connector credentials, route ciphertext, sessions, link/OAuth transactions, internal jobs |
| `conversations` | conversations and turns retained by Attune, with source provenance and timestamps | provider access tokens, raw task payloads, hidden model/tool authority |
| `memories` | explicit memories and source metadata | raw embedding vectors and model-provider secrets |
| `activity` | customer-visible audit events and usage records | audit-chain internals, security-only events, IP/device abuse evidence, internal identifiers unrelated to the owner |

The schema-versioned manifest identifies Attune, tenant export scope, request
and generation timestamps, format versions, record counts, and a digest for
each payload member. Stable customer-facing identifiers may be included;
database implementation details and unrelated principals may not.

## Trust boundaries

- **Control plane:** authenticates the owner, enforces recent authentication,
  creates only a fixed request, and serves status. It cannot read export
  content, choose an object path, or unwrap an export key.
- **Dispatch broker:** queues only an opaque canonical export intent. Browser
  data cannot become worker arguments.
- **Export executor:** a dedicated identity claims one pending job through a
  fixed database function. Its database owner can read only the reviewed
  export projection and update only that job's state. It has no connector,
  secret-broker, queue-administration, or general storage-list authority.
- **Export crypto/storage writer:** creates a random per-export data-encryption
  key, encrypts the archive with authenticated context binding tenant, job,
  scope, and schema version, wraps the key with the export KMS key, and creates
  only the canonical opaque object name. Partial objects are deleted on every
  failure path.
- **Download gateway:** after a second recent-auth ceremony, atomically consumes
  the download authorization, reads exactly the referenced object generation,
  unwraps and streams it, and schedules immediate erasure. It never redirects
  to a public or long-lived bearer URL.
- **Cleanup executor:** deletes expired/consumed object generations and wrapped
  keys in bounded batches, then records content-free evidence. Bucket lifecycle
  is a backstop, not proof that application cleanup succeeded.

The storage bucket is separate from retained audit evidence, uses a separate
KMS key, uniform access, public-access prevention, versioning disabled, a
24-hour lifecycle ceiling, and provider-enforced deletion protection. No
principal receives bucket-wide read/list plus key-decrypt authority.

## State machine and concurrency

The allowed transitions are:

```text
requested -> running -> ready -> consumed -> expired
                    \-> failed
requested ---------> cancelled
```

Claims use a one-use lease and idempotency key. At most one active export per
owner and scope is allowed. A ready record binds the opaque object UUID, exact
storage generation, wrapped-key ciphertext, archive digest, byte size, and an
expiry no later than 24 hours after readiness. Download consumption is atomic;
parallel or replayed requests cannot both obtain plaintext. A failed,
cancelled, consumed, or expired job cannot return to ready.

## Content and format safety

The archive is size- and record-bounded, deterministic JSON Lines plus a JSON
manifest, compressed before authenticated encryption. Text remains data: it is
never evaluated as templates, HTML, spreadsheet formulas, paths, or tool
instructions. Member names are fixed, UTF-8 is validated, control characters
are escaped, and archive extraction cannot create absolute paths or `..`
segments.

Generation applies a structural secret-negative policy before encryption and
again to a test decryption: forbidden column classes, OAuth/token/key field
names, connector ciphertext, route ciphertext, sessions, link secrets, raw
embeddings, internal task authority, and unreviewed tables fail the job closed.
Regex redaction is not the authorization boundary.

## Required evidence before activation

- real-PostgreSQL cross-tenant, role, claim/replay, transition, and concurrency
  tests through the exact runtime identities;
- fixtures containing canary credentials and adversarial archive/text values,
  proving no forbidden field or path escapes;
- envelope-encryption substitution tests for tenant, job, scope, generation,
  and object context;
- partial-write, KMS failure, retry, double-download, expiry, and cleanup tests;
- a synthetic development export whose decrypted manifest and payload are
  reviewed, followed by object/key cleanup and an empty infrastructure plan;
- paging for generation failure, cleanup failure, and expired-object backlog;
- a staging restore exercise proving a consumed/expired export cannot reappear;
  and
- independent security review before any production customer export.

Until these gates pass, the control plane must describe export as unavailable;
it must not present a decorative or nonfunctional download control.
