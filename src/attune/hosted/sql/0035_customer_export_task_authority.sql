-- Bind Cloud Tasks delivery to one canonical export job without granting the
-- export runtime direct access to generic jobs or dispatch intents.
CREATE FUNCTION attune.claim_customer_export_for_tenant(
    p_tenant_id uuid, p_export_id uuid, p_run_id uuid
)
RETURNS TABLE (
    tenant_id uuid, export_id uuid, requested_by uuid, scope_name text,
    lease_expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_claim record;
BEGIN
    IF NOT pg_catalog.pg_has_role(session_user, 'attune_export', 'MEMBER') THEN
        RAISE EXCEPTION 'export executor is unauthorized' USING ERRCODE = '42501';
    END IF;
    IF p_tenant_id IS NULL OR p_export_id IS NULL OR p_run_id IS NULL THEN
        RAISE EXCEPTION 'invalid tenant-bound export claim' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_claim
      FROM attune.claim_customer_export(p_export_id, p_run_id);
    IF NOT FOUND THEN
        RETURN;
    END IF;
    IF v_claim.tenant_id <> p_tenant_id THEN
        RAISE EXCEPTION 'export tenant does not match task authority' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT v_claim.tenant_id, v_claim.export_id,
                        v_claim.requested_by, v_claim.scope_name,
                        v_claim.lease_expires_at;
END
$function$;

CREATE FUNCTION attune.claim_customer_export_task(
    p_tenant_id uuid, p_job_id uuid, p_delivery_id uuid
)
RETURNS TABLE (export_id uuid, task_state text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_export_id uuid;
    v_state text;
BEGIN
    IF NOT pg_catalog.pg_has_role(session_user, 'attune_export', 'MEMBER') THEN
        RAISE EXCEPTION 'export task caller is unauthorized' USING ERRCODE = '42501';
    END IF;
    IF p_tenant_id IS NULL OR p_job_id IS NULL OR p_delivery_id IS NULL THEN
        RAISE EXCEPTION 'invalid export task claim' USING ERRCODE = '22023';
    END IF;

    WITH candidate AS MATERIALIZED (
        SELECT job.tenant_id, job.id, export.id AS export_id
          FROM attune.jobs AS job
          JOIN attune.dispatch_intents AS intent
            ON intent.tenant_id = job.tenant_id AND intent.job_id = job.id
          JOIN attune.export_jobs AS export
            ON export.tenant_id = job.tenant_id
           AND job.payload = pg_catalog.jsonb_build_object(
               'export_id', export.id::text)
         WHERE job.tenant_id = p_tenant_id AND job.id = p_job_id
           AND intent.delivery_id = p_delivery_id
           AND intent.state IN ('leased', 'dispatched')
           AND intent.purpose = 'customer.export.generate'
           AND intent.capability = 'customer.export.generate'
           AND job.kind = intent.purpose AND job.capability = intent.capability
           AND job.available_at <= clock_timestamp()
           AND (
               job.state = 'queued'
               OR (job.state = 'leased'
                   AND job.lease_expires_at <= clock_timestamp())
           )
         FOR UPDATE OF job
    ), claimed AS (
        UPDATE attune.jobs AS job
           SET state = 'leased', attempts = job.attempts + 1,
               lease_expires_at = clock_timestamp() + interval '6 minutes',
               updated_at = clock_timestamp()
          FROM candidate
         WHERE job.tenant_id = candidate.tenant_id AND job.id = candidate.id
        RETURNING candidate.export_id
    )
    SELECT claimed.export_id, 'claimed'::text
      INTO v_export_id, v_state FROM claimed;

    IF FOUND THEN
        RETURN QUERY SELECT v_export_id, v_state;
        RETURN;
    END IF;

    SELECT export.id AS export_id,
           CASE
               WHEN job.state = 'leased' THEN 'busy'
               WHEN job.state = 'succeeded' THEN 'succeeded'
               WHEN job.state IN ('failed', 'cancelled', 'reconcile') THEN 'failed'
               ELSE NULL
           END
      INTO v_export_id, v_state
      FROM attune.jobs AS job
      JOIN attune.dispatch_intents AS intent
        ON intent.tenant_id = job.tenant_id AND intent.job_id = job.id
      JOIN attune.export_jobs AS export
        ON export.tenant_id = job.tenant_id
       AND job.payload = pg_catalog.jsonb_build_object('export_id', export.id::text)
     WHERE job.tenant_id = p_tenant_id AND job.id = p_job_id
       AND intent.delivery_id = p_delivery_id
       AND intent.state IN ('leased', 'dispatched')
       AND intent.purpose = 'customer.export.generate'
       AND intent.capability = 'customer.export.generate'
       AND job.kind = intent.purpose AND job.capability = intent.capability;
    IF FOUND AND v_state IS NOT NULL THEN
        RETURN QUERY SELECT v_export_id, v_state;
    END IF;
END
$function$;

CREATE FUNCTION attune.finish_customer_export_task(
    p_tenant_id uuid, p_job_id uuid, p_delivery_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_outcome text;
BEGIN
    IF NOT pg_catalog.pg_has_role(session_user, 'attune_export', 'MEMBER') THEN
        RAISE EXCEPTION 'export task caller is unauthorized' USING ERRCODE = '42501';
    END IF;
    IF p_tenant_id IS NULL OR p_job_id IS NULL OR p_delivery_id IS NULL THEN
        RAISE EXCEPTION 'invalid export task completion' USING ERRCODE = '22023';
    END IF;
    UPDATE attune.jobs AS job
       SET state = CASE
               WHEN export.state IN ('ready', 'consumed', 'expired') THEN 'succeeded'
               ELSE 'failed'
           END,
           lease_expires_at = NULL, updated_at = clock_timestamp()
      FROM attune.dispatch_intents AS intent, attune.export_jobs AS export
     WHERE job.tenant_id = p_tenant_id AND job.id = p_job_id
       AND job.state = 'leased'
       AND intent.tenant_id = job.tenant_id AND intent.job_id = job.id
       AND intent.delivery_id = p_delivery_id
       AND intent.state IN ('leased', 'dispatched')
       AND intent.purpose = 'customer.export.generate'
       AND intent.capability = 'customer.export.generate'
       AND job.kind = intent.purpose AND job.capability = intent.capability
       AND export.tenant_id = job.tenant_id
       AND job.payload = pg_catalog.jsonb_build_object('export_id', export.id::text)
       AND export.state IN (
           'ready', 'consumed', 'expired', 'failed', 'cancelled')
    RETURNING job.state INTO v_outcome;
    IF FOUND THEN
        RETURN v_outcome;
    END IF;
    SELECT job.state INTO v_outcome
      FROM attune.jobs AS job
      JOIN attune.dispatch_intents AS intent
        ON intent.tenant_id = job.tenant_id AND intent.job_id = job.id
     WHERE job.tenant_id = p_tenant_id AND job.id = p_job_id
       AND intent.delivery_id = p_delivery_id
       AND intent.state IN ('leased', 'dispatched')
       AND intent.purpose = 'customer.export.generate'
       AND job.kind = intent.purpose AND job.capability = intent.capability
       AND job.state IN ('succeeded', 'failed');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'terminal export state is required' USING ERRCODE = '42501';
    END IF;
    RETURN v_outcome;
END
$function$;

DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format('GRANT attune_export_coordinator TO %I', current_user);
END
$grant_owner$;
GRANT USAGE, CREATE ON SCHEMA attune TO attune_export_coordinator;
GRANT SELECT, UPDATE ON attune.jobs TO attune_export_coordinator;
GRANT SELECT ON attune.dispatch_intents TO attune_export_coordinator;
ALTER FUNCTION attune.claim_customer_export_for_tenant(uuid, uuid, uuid)
OWNER TO attune_export_coordinator;
ALTER FUNCTION attune.claim_customer_export_task(uuid, uuid, uuid)
OWNER TO attune_export_coordinator;
ALTER FUNCTION attune.finish_customer_export_task(uuid, uuid, uuid)
OWNER TO attune_export_coordinator;
REVOKE CREATE ON SCHEMA attune FROM attune_export_coordinator;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format('REVOKE attune_export_coordinator FROM %I', current_user);
END
$revoke_owner$;
REVOKE ALL ON FUNCTION
    attune.claim_customer_export_for_tenant(uuid, uuid, uuid),
    attune.claim_customer_export_task(uuid, uuid, uuid),
    attune.finish_customer_export_task(uuid, uuid, uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.claim_customer_export_for_tenant(uuid, uuid, uuid),
    attune.claim_customer_export_task(uuid, uuid, uuid),
    attune.finish_customer_export_task(uuid, uuid, uuid)
TO attune_export;
