# Operated SaaS on Google Cloud

GCP is Attune's first operated SaaS platform. This is a platform decision, not
a change to the portable self-hosted product: `attune init --target local` and
polling deployments continue to work without hosted Attune.

The normative requirements remain in
[`security-architecture.md`](security-architecture.md). This document maps them
to the first GCP implementation.

## Trust boundaries and services

| Boundary | GCP implementation | Holds customer credentials? | Public? |
|---|---|---:|---:|
| Web control plane | Cloud Run behind external HTTPS load balancing and Cloud Armor | No | Yes |
| Provider/channel ingress | Dedicated Cloud Run service with verified Slack, Chat, Calendar, and Pub/Sub handlers | Signing material only where verification requires it | Yes |
| Durable dispatch | Cloud Tasks with a dedicated OIDC dispatch identity | No | No |
| Tenant worker | Private Cloud Run service, one signed tenant/job envelope per request | No | IAM only |
| Secret broker | Private Cloud Run service with the only connector-vault KMS identity | Yes | IAM only |
| Relational/vector data | Private-IP Cloud SQL PostgreSQL with IAM authentication, RLS, and `vector` | No | No |
| Audit writer | Private service writing canonical events to PostgreSQL and retained Cloud Storage | No | IAM only |
| Images | Artifact Registry with provenance and vulnerability policy gates | No | No |

Every service has a distinct user-managed service account. Google recommends
per-service identities and Google-signed OIDC tokens for Cloud Run
service-to-service calls. Cloud Tasks likewise sends OIDC tokens to authenticated
Cloud Run handlers. Request headers that merely resemble Cloud Tasks metadata
are not identity.

## Data model

The hosted service does not mount or share `.env`, SQLite, JSON, JSONL, or a
local Qdrant volume. PostgreSQL owns accounts, installations, connectors,
policies, jobs, approvals, audit metadata, and vector rows. Every customer row
contains an immutable tenant identifier; RLS derives access from a transaction-
local server setting established from a verified internal job or session.
Application queries must not accept an arbitrary tenant id as authority.

The first hosted vector implementation is PostgreSQL `vector`, not shared
Qdrant. This reduces the number of privileged data systems and lets relational
and vector access use the same transaction, RLS, backup, export, and deletion
boundary. The existing memory interface remains the application abstraction.

## Credential flow

1. The authenticated control plane creates an OAuth transaction bound to the
   browser session, intended tenant, PKCE verifier, exact redirect URI, state,
   and expiry.
2. The callback validates the transaction and sends the resulting credential
   directly to the private secret broker.
3. The broker envelope-encrypts the credential with the connector-vault KMS
   key, stores tenant-bound versioned ciphertext in PostgreSQL, and returns an
   opaque connector reference. It never returns the refresh token to the
   control plane or worker.
4. A worker presents a signed internal job and exact capability to the broker.
   Policy is rechecked; the broker either performs the provider operation or
   issues a narrowly bounded, short-lived access path.
5. Access, refusal, rotation, replacement, and revocation produce content-free
   audit events.

Secret Manager holds static platform credentials such as OAuth client and Slack
signing material; it is not a per-customer token database. The foundation
creates empty platform-secret containers only. Tenant credentials use the
connector vault described above. No secret value may enter Terraform state,
Cloud Run environment variables, plans, build logs, or support bundles.

## Ingress flow

Public handlers authenticate the provider over the raw request, enforce size
and timestamp limits, normalize only identifiers needed for reconciliation,
deduplicate, enqueue, and return promptly. Gmail publishes to the dedicated
topic; its eventual push subscription must use a service account and an exact
OIDC audience. Calendar and channel notifications are signals to fetch current
provider state, never executable instructions.

The Google-managed Gmail publisher receives only `roles/pubsub.publisher` on
that topic. If legacy Domain Restricted Sharing blocks the external system
principal, operators must use the documented, audited project-scoped
break-glass procedure in the foundation README and restore the constraint
immediately. Public topic access and permanent policy exceptions are not
acceptable substitutes.

## Deployment order and gates

1. **Foundation:** apply `deploy/gcp/foundation` in development and staging;
   verify private networking, IAM, CMEK recovery, backup restore, queues, and
   audit retention. No customer data is allowed.
2. **Hosted schema and adapters:** migrations, RLS, tenant-context enforcement,
   PostgreSQL vector storage, queue envelopes, and tamper-evident audit events.
3. **Secret broker:** connector storage, use, rotation, revocation, and negative
   authorization tests.
4. **Control plane:** OIDC/passkey login and explicit connector identity links.
5. **Ingress and workers:** provider verification, replay resistance,
   reconciliation, deterministic capabilities, and kill switches.
6. **Operations:** load balancer/WAF, alerts, SLOs, backups/restores, export,
   deletion, incident response, support controls, and supply-chain enforcement.
7. **Assurance:** tenant-isolation suite, red team, independent penetration
   test, Google OAuth verification/CASA evidence, and launch-gate review.

Production is blocked until every launch gate in `security-architecture.md` is
evidenced. Successfully applying Terraform is not successful onboarding.

## Operator workflow

The operated platform is provisioned by a restricted platform identity from
reviewed infrastructure changes. End users never run Terraform or receive GCP
roles. Their eventual journey is sign in, connect Google, optionally connect
Slack or enable Google Chat, select destinations and policy, run bounded live
tests, and activate Attune. Hosted onboarding reuses the versioned setup-state
concept, but stores only server-side, tenant-bound progress and opaque resource
references—not `.env` files or credentials.

## GCP implementation references

- [Cloud Run service identities](https://cloud.google.com/run/docs/securing/service-identity)
  and [authenticated service-to-service calls](https://cloud.google.com/run/docs/authenticating/service-to-service)
- [Cloud Tasks HTTP targets with OIDC](https://cloud.google.com/tasks/docs/creating-http-target-tasks)
- [Cloud SQL private IP](https://cloud.google.com/sql/docs/postgres/configure-private-ip),
  [IAM database authentication](https://cloud.google.com/sql/docs/postgres/iam-authentication),
  and [row-level security](https://cloud.google.com/sql/docs/postgres/data-privacy-strategies)
- [Secret Manager CMEK](https://cloud.google.com/secret-manager/docs/cmek)
  and [Cloud Storage Bucket Lock](https://cloud.google.com/storage/docs/bucket-lock)
- [authenticated Pub/Sub push](https://cloud.google.com/pubsub/docs/authenticate-push-subscriptions)
