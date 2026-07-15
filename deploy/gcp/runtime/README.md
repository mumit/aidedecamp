# GCP hosted runtime boundaries

This independent Terraform root deploys private hosted services after the
foundation and database migrations pass. It currently deploys the audit writer
and credential-mutation secret broker; the dispatch broker and deterministic
workers join this root only after their own security gates pass.

## Audit-writer boundary

The service accepts exactly one canonical audit-intent UUID. It never accepts a
tenant, actor, action, outcome, metadata, or event body over HTTP. Control-plane,
worker, secret-broker, and dispatch-broker identities may invoke the private
service with Google IAM; no public principal may invoke it.

The audit-writer identity has no direct table privilege and cannot call the old
free-form append function. Its only database authority is the
`write_audit_intent(uuid)` function. That function resolves the durable intent,
sets its tenant context, appends one hash-chained event, and marks the intent
written in one transaction. Replays return the existing event. Unknown IDs do
nothing. Audit failures return a generic error and callers must fail closed for
security-sensitive work.

## Secret-broker boundary

The secret broker accepts only an opaque credential-intent UUID, plus the
credential object for an install. Cloud Run IAM permits only the control-plane
service account to invoke it. A stable custom audience is checked again inside
the application, and caller-supplied tenant or connector authority is rejected.
The broker alone can use the connector credential KMS key and its narrow
database functions. It requires the private audit writer before and after a
mutation and fails closed on ambiguous results.

## Development deployment

Apply `deploy/gcp/data` and successfully execute its migrator before deploying
this root. Build Linux/amd64 and deploy only by immutable digest:

```bash
export PROJECT_ID="your-development-project"
export REGION="northamerica-northeast1"
export REPOSITORY="attune-development"
export AUDIT_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/attune-audit-writer"
export BROKER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/attune-secret-broker"

docker buildx build --platform=linux/amd64 --push \
  -f deploy/audit-writer/Dockerfile -t "${AUDIT_IMAGE}:audit-writer-v1" .
docker buildx build --platform=linux/amd64 --push \
  -f deploy/secret-broker/Dockerfile -t "${BROKER_IMAGE}:secret-broker-v1" .
gcloud artifacts docker images describe "${AUDIT_IMAGE}:audit-writer-v1" \
  --project="$PROJECT_ID" \
  --format='value(image_summary.fully_qualified_digest)'
gcloud artifacts docker images describe "${BROKER_IMAGE}:secret-broker-v1" \
  --project="$PROJECT_ID" \
  --format='value(image_summary.fully_qualified_digest)'
```

Copy the examples to ignored local files, put the returned digest in
`terraform.tfvars`, initialize the isolated state, and review a saved plan:

```bash
cd deploy/gcp/runtime
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform validate
terraform plan -out=runtime.tfplan
terraform apply runtime.tfplan
```

Verify that both services have internal ingress and reject unauthenticated
invocation. The audit-writer IAM policy must list only its four expected
workloads; the broker policy must list only the control plane. Verify the broker
custom audience and that neither service account has a user-managed key. Do not
place tenant data, tokens, or credentials in Terraform variables, state,
labels, probes, or deployment logs.

For a release candidate, validate the live connector key using the exact
digest already reviewed in `terraform.tfvars`. This creates no tenant or
credential record: it generates a random 256-bit value in memory, verifies a
KMS wrap/unwrap with CRC32C integrity, clears the plaintext buffers, and prints
only pass/fail. The job is intentionally ephemeral so the KMS-capable identity
does not gain another standing execution surface:

```bash
# Use the secret_broker.image value from `terraform output -json` for IMAGE.
export IMAGE="northamerica-northeast1-docker.pkg.dev/PROJECT/REPOSITORY/attune-secret-broker@sha256:DIGEST"
export BROKER_SA="attune-ENVIRONMENT-secrets@PROJECT.iam.gserviceaccount.com"
export KMS_KEY="projects/PROJECT/locations/REGION/keyRings/attune-ENVIRONMENT/cryptoKeys/connector-credentials"

gcloud run jobs create "attune-ENVIRONMENT-kms-smoke" \
  --project="$PROJECT_ID" --region="$REGION" --image="$IMAGE" \
  --service-account="$BROKER_SA" \
  --set-env-vars="ATTUNE_CONNECTOR_KMS_KEY=$KMS_KEY" \
  --command=python --args=-m,attune.hosted.kms_smoke \
  --tasks=1 --max-retries=0 --task-timeout=120s --execute-now --wait
gcloud run jobs delete "attune-ENVIRONMENT-kms-smoke" \
  --project="$PROJECT_ID" --region="$REGION" --quiet
```

Do not retain the job, replace the random input with a real credential, or put
secret values in command arguments or environment variables.
