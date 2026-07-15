# GCP hosted edge

This independent Terraform root creates the locked public HTTPS boundary for
the hosted control plane. The initial service exposes only `GET /healthz` and an
unavailable root. A separately identified, credential-free callback scrubber
accepts the exact Google callback path only to remove query parameters from the
browser URL. The private OAuth exchange is deployed but not connected to this
scrubber. Signup, sessions, connector installation, and customer traffic remain
disabled.

The edge uses a reserved global IPv4 address, global external Application Load
Balancer, Google-managed certificate, TLS 1.2+ policy, serverless NEG, and Cloud
Armor. Cloud Run accepts external traffic only from Cloud Load Balancing and
its default `run.app` URI is disabled. The Cloud Run invoker IAM check is
disabled because the load balancer cannot mint a Cloud Run identity token. This
also avoids an `allUsers` IAM grant, which domain-restricted-sharing policies
reject. Disabling the check is safe only in combination with both ingress
restrictions and the disabled default URI.

The shell policy permits only `/` and `/healthz` on the exact configured host.
A distinct policy permits only `GET /oauth/google/callback` with a tighter
source-IP rate. The callback backend has load-balancer logging disabled, and a
protected project exclusion drops both Cloud Run platform request logs and
Cloud Armor/load-balancer request logs by the dedicated service/backend resource
identities. Disabling backend logging alone is insufficient because Cloud Armor
can still emit `requests` entries. The exclusion does not match on or inspect
the credential-bearing URL. The scrubber parses no OAuth fields, has no
access-log, database, secret, KMS, queue, or provider authority, and redirects
to `/` with HTTP 303. The foundation's immutable sink exports Cloud Audit logs
only.

These controls establish URL non-retention; they do not activate OAuth. The
server-side one-time transaction, PKCE exchange, and private broker handoff are
implemented behind the dormant boundary. Hosted sign-in/session binding,
identity-link validation, a reviewed OAuth client, callback-to-exchange wiring,
content-free live audit evidence, and adversarial tests remain launch gates.

## Build and apply

Build Linux/amd64, push, and resolve the immutable digest:

```bash
export PROJECT_ID="your-development-project"
export REGION="northamerica-northeast1"
export REPOSITORY="attune-development"
export IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/attune-control-plane"
export CALLBACK_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/attune-oauth-callback"

docker buildx build --platform=linux/amd64 --push \
  -f deploy/control-plane/Dockerfile -t "${IMAGE}:locked-edge-v1" .
gcloud artifacts docker images describe "${IMAGE}:locked-edge-v1" \
  --project="$PROJECT_ID" \
  --format='value(image_summary.fully_qualified_digest)'
docker buildx build --platform=linux/amd64 --push \
  -f deploy/oauth-callback/Dockerfile -t "${CALLBACK_IMAGE}:dormant-v1" .
gcloud artifacts docker images describe "${CALLBACK_IMAGE}:dormant-v1" \
  --project="$PROJECT_ID" \
  --format='value(image_summary.fully_qualified_digest)'
```

Copy the examples to ignored local files, set the reviewed image digest and
exact hostname, then use a saved plan:

```bash
cd deploy/gcp/edge
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform fmt -check
terraform validate
terraform plan -out=edge.tfplan
terraform show edge.tfplan
terraform apply edge.tfplan
terraform output -json edge
```

Create exactly the output `A` record at the authoritative DNS provider. The
Google-managed certificate remains `PROVISIONING` until DNS points at the
reserved address and can take time to become active. Do not create an OAuth
client until HTTPS health, direct-URL denial, exact-host denial, Cloud Armor,
and callback-log non-retention have passed.

After applying, send a synthetic callback containing unmistakable fake values,
then prove the 303 strips them and neither request-log plane retained them:

```bash
curl -sS -D - -o /dev/null \
  'https://dev.attune.example.com/oauth/google/callback?code=ATTUNE_FAKE_CODE&state=ATTUNE_FAKE_STATE'
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="attune-development-oauth-callback" AND log_id("run.googleapis.com/requests")' \
  --freshness=15m --limit=10
gcloud logging read \
  'resource.type="http_load_balancer" AND resource.labels.backend_service_name="attune-development-oauth-callback"' \
  --freshness=15m --limit=10
```

Both reads must be empty. Also search all project logs for the two fake values.
Never use a real authorization code for this test.

Do not put even a synthetic marker into the `gcloud logging read` filter:
Data Access audit logs record that filter, making the search self-retaining.
Instead record a narrow start/end time, fetch that whole log window using only
the timestamps in the server-side filter, and search the returned JSON locally.
The callback marker must be absent. Real authorization codes, tokens, and state
values must never appear in an operator command or log query.

URL-map changes converge asynchronously across the global data plane. During
that interval the old shell backend can still deny—and log—the callback path.
Therefore the OAuth client MUST NOT exist or list this redirect URI until
query-free probes return 303 after a documented soak, multi-location synthetic
markers return 303, and every marker is absent from all project logs after the
normal ingestion window. This ordering prevents real authorization codes from
arriving while an older logged route is still serving.
