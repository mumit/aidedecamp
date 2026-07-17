-- Recoverable export execution. The object UUID is durably reserved before an
-- upload, so a replacement executor can delete an ambiguous partial object by
-- its canonical name without storage list or read authority.
ALTER TABLE attune.export_jobs
    ADD COLUMN failure_code text,
    ADD COLUMN failure_run_id uuid,
    ADD CONSTRAINT export_jobs_failure_check CHECK (
        (state = 'failed'
         AND failure_code IN (
             'projection_failed', 'archive_failed', 'encryption_failed',
             'upload_failed', 'completion_failed'
         )
         AND failure_run_id IS NOT NULL)
        OR (state <> 'failed'
            AND failure_code IS NULL AND failure_run_id IS NULL)
    );

CREATE TABLE attune.export_object_attempts (
    tenant_id uuid NOT NULL,
    export_id uuid NOT NULL,
    run_id uuid NOT NULL,
    object_ref uuid,
    cleanup_pending boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    cleaned_at timestamptz,
    PRIMARY KEY (tenant_id, export_id, run_id),
    FOREIGN KEY (tenant_id, export_id)
        REFERENCES attune.export_jobs(tenant_id, id) ON DELETE CASCADE,
    CHECK (
        (cleanup_pending AND cleaned_at IS NULL)
        OR (NOT cleanup_pending AND cleaned_at IS NOT NULL)
    )
);
ALTER TABLE attune.export_object_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE attune.export_object_attempts FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON attune.export_object_attempts
USING (tenant_id = attune.current_tenant_id())
WITH CHECK (tenant_id = attune.current_tenant_id());

-- The claim function is already owned by the memberless coordinator. Assume
-- that role only for this transaction so replacement never relies on broad
-- migrator ownership or persistent membership.
DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format('GRANT attune_export_coordinator TO %I', current_user);
END
$grant_owner$;
GRANT USAGE, CREATE ON SCHEMA attune TO attune_export_coordinator;

CREATE OR REPLACE FUNCTION attune.claim_customer_export(
    p_export_id uuid, p_run_id uuid
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
    v_job record;
BEGIN
    IF NOT pg_catalog.pg_has_role(session_user, 'attune_export', 'MEMBER') THEN
        RAISE EXCEPTION 'export executor is unauthorized' USING ERRCODE = '42501';
    END IF;
    IF p_export_id IS NULL OR p_run_id IS NULL THEN
        RAISE EXCEPTION 'invalid export claim' USING ERRCODE = '22023';
    END IF;

    UPDATE attune.export_jobs AS job
       SET state = 'running', lease_run_id = p_run_id,
           lease_expires_at = clock_timestamp() + interval '5 minutes',
           object_ref = NULL,
           updated_at = clock_timestamp()
     WHERE job.id = p_export_id
       AND (
           job.state = 'requested'
           OR (job.state = 'running'
               AND job.lease_expires_at <= clock_timestamp())
       )
    RETURNING job.tenant_id AS tenant_id, job.id AS id,
              job.requested_by AS requested_by,
              job.scope ->> 'name' AS scope_name,
              job.lease_expires_at AS lease_expires_at
         INTO v_job;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    INSERT INTO attune.export_object_attempts (
        tenant_id, export_id, run_id
    ) VALUES (v_job.tenant_id, v_job.id, p_run_id);

    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type,
        action, outcome, target_type, target_ref_hash, metadata
    ) VALUES (
        v_job.tenant_id, 'export',
        attune_ext.digest(pg_catalog.convert_to(
            'export-claim-v1:' || p_run_id::text, 'UTF8'), 'sha256'),
        'system', 'export.claimed', 'observed', 'export_job',
        attune_ext.digest(pg_catalog.convert_to(
            v_job.id::text, 'UTF8'), 'sha256'),
        pg_catalog.jsonb_build_object('scope', v_job.scope_name)
    );

    RETURN QUERY SELECT v_job.tenant_id, v_job.id, v_job.requested_by,
                        v_job.scope_name, v_job.lease_expires_at;
END
$function$;

CREATE FUNCTION attune.reserve_customer_export_object(
    p_export_id uuid, p_run_id uuid, p_proposed_object_id uuid
)
RETURNS TABLE (object_id uuid, requested_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_job record;
BEGIN
    IF NOT pg_catalog.pg_has_role(session_user, 'attune_export', 'MEMBER') THEN
        RAISE EXCEPTION 'export executor is unauthorized' USING ERRCODE = '42501';
    END IF;
    IF p_export_id IS NULL OR p_run_id IS NULL OR p_proposed_object_id IS NULL THEN
        RAISE EXCEPTION 'invalid export object reservation' USING ERRCODE = '22023';
    END IF;

    UPDATE attune.export_object_attempts AS attempt
       SET object_ref = coalesce(attempt.object_ref, p_proposed_object_id)
      FROM attune.export_jobs AS job
     WHERE job.id = p_export_id AND job.state = 'running'
       AND job.lease_run_id = p_run_id
       AND job.lease_expires_at > clock_timestamp()
       AND attempt.tenant_id = job.tenant_id
       AND attempt.export_id = job.id AND attempt.run_id = p_run_id
    RETURNING attempt.object_ref, job.created_at INTO v_job;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'active export claim is required' USING ERRCODE = '42501';
    END IF;
    UPDATE attune.export_jobs AS job
       SET object_ref = v_job.object_ref, updated_at = clock_timestamp()
     WHERE job.id = p_export_id AND job.state = 'running'
       AND job.lease_run_id = p_run_id;
    RETURN QUERY SELECT v_job.object_ref, v_job.created_at;
END
$function$;

CREATE FUNCTION attune.list_customer_export_cleanup_objects(
    p_export_id uuid, p_run_id uuid
)
RETURNS TABLE (attempt_run_id uuid, object_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    IF NOT pg_catalog.pg_has_role(session_user, 'attune_export', 'MEMBER') THEN
        RAISE EXCEPTION 'export executor is unauthorized' USING ERRCODE = '42501';
    END IF;
    IF p_export_id IS NULL OR p_run_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM attune.export_jobs AS job
         WHERE job.id = p_export_id AND job.state = 'running'
           AND job.lease_run_id = p_run_id
           AND job.lease_expires_at > clock_timestamp()
    ) THEN
        RAISE EXCEPTION 'active export claim is required' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY
    SELECT attempt.run_id, attempt.object_ref
      FROM attune.export_object_attempts AS attempt
     WHERE attempt.export_id = p_export_id
       AND attempt.run_id <> p_run_id
       AND attempt.cleanup_pending AND attempt.object_ref IS NOT NULL
     ORDER BY attempt.created_at, attempt.run_id;
END
$function$;

CREATE FUNCTION attune.fail_customer_export(
    p_export_id uuid, p_run_id uuid, p_failure_code text
)
RETURNS TABLE (export_id uuid, export_state text, failure_code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_job record;
BEGIN
    IF NOT pg_catalog.pg_has_role(session_user, 'attune_export', 'MEMBER') THEN
        RAISE EXCEPTION 'export executor is unauthorized' USING ERRCODE = '42501';
    END IF;
    IF p_export_id IS NULL OR p_run_id IS NULL
       OR p_failure_code NOT IN (
           'projection_failed', 'archive_failed', 'encryption_failed',
           'upload_failed', 'completion_failed'
       ) THEN
        RAISE EXCEPTION 'invalid export failure' USING ERRCODE = '22023';
    END IF;

    UPDATE attune.export_jobs AS job
       SET state = 'failed', failure_code = p_failure_code,
           failure_run_id = p_run_id, object_ref = NULL,
           object_generation = NULL, wrapped_dek = NULL, nonce = NULL,
           key_resource = NULL, archive_sha256 = NULL,
           ciphertext_sha256 = NULL, archive_bytes = NULL,
           ciphertext_bytes = NULL, encryption_format = NULL,
           ready_at = NULL, expires_at = NULL,
           lease_run_id = NULL, lease_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE job.id = p_export_id AND job.state = 'running'
       AND job.lease_run_id = p_run_id
       AND job.lease_expires_at > clock_timestamp()
    RETURNING job.id, job.state, job.failure_code INTO v_job;

    IF NOT FOUND THEN
        SELECT job.id, job.state, job.failure_code INTO v_job
          FROM attune.export_jobs AS job
         WHERE job.id = p_export_id AND job.state = 'failed'
           AND job.failure_run_id = p_run_id
           AND job.failure_code = p_failure_code;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'active export claim is required' USING ERRCODE = '42501';
        END IF;
    ELSE
        UPDATE attune.export_object_attempts AS attempt
           SET cleanup_pending = false, cleaned_at = clock_timestamp()
         WHERE attempt.export_id = p_export_id
           AND attempt.run_id = p_run_id;
        INSERT INTO attune.audit_intents (
            tenant_id, producer_kind, idempotency_key, actor_type,
            action, outcome, target_type, target_ref_hash, metadata
        ) SELECT job.tenant_id, 'export',
            attune_ext.digest(pg_catalog.convert_to(
                'export-failed-v1:' || p_run_id::text, 'UTF8'), 'sha256'),
            'system', 'export.failed', 'failed', 'export_job',
            attune_ext.digest(pg_catalog.convert_to(
                p_export_id::text, 'UTF8'), 'sha256'),
            pg_catalog.jsonb_build_object(
                'scope', job.scope ->> 'name',
                'failure_code', p_failure_code)
          FROM attune.export_jobs AS job WHERE job.id = p_export_id
        ON CONFLICT (tenant_id, idempotency_key) DO NOTHING;
    END IF;
    RETURN QUERY SELECT v_job.id, v_job.state, v_job.failure_code;
END
$function$;

GRANT SELECT, INSERT, UPDATE ON attune.export_object_attempts
TO attune_export_coordinator;
ALTER FUNCTION attune.claim_customer_export(uuid, uuid)
OWNER TO attune_export_coordinator;
ALTER FUNCTION attune.reserve_customer_export_object(uuid, uuid, uuid)
OWNER TO attune_export_coordinator;
ALTER FUNCTION attune.list_customer_export_cleanup_objects(uuid, uuid)
OWNER TO attune_export_coordinator;
ALTER FUNCTION attune.fail_customer_export(uuid, uuid, text)
OWNER TO attune_export_coordinator;
REVOKE CREATE ON SCHEMA attune FROM attune_export_coordinator;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format('REVOKE attune_export_coordinator FROM %I', current_user);
END
$revoke_owner$;
REVOKE ALL ON FUNCTION
    attune.reserve_customer_export_object(uuid, uuid, uuid),
    attune.list_customer_export_cleanup_objects(uuid, uuid),
    attune.fail_customer_export(uuid, uuid, text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.reserve_customer_export_object(uuid, uuid, uuid),
    attune.list_customer_export_cleanup_objects(uuid, uuid),
    attune.fail_customer_export(uuid, uuid, text)
TO attune_export;
