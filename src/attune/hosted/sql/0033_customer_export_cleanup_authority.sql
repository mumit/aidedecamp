-- Dedicated, bounded cleanup authority for abandoned export-attempt objects.
-- Ready export objects are explicitly excluded and receive a later exact-
-- generation expiry/consumption protocol.
DO $roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'attune_export_cleanup') THEN
        CREATE ROLE attune_export_cleanup
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'attune_export_cleanup_coordinator') THEN
        CREATE ROLE attune_export_cleanup_coordinator
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
    END IF;
END
$roles$;

ALTER TABLE attune.export_object_attempts
    ADD COLUMN cleanup_lease_run_id uuid,
    ADD COLUMN cleanup_lease_expires_at timestamptz,
    ADD CONSTRAINT export_object_attempts_cleanup_lease_check CHECK (
        (cleanup_lease_run_id IS NULL AND cleanup_lease_expires_at IS NULL)
        OR (cleanup_pending AND cleanup_lease_run_id IS NOT NULL
            AND cleanup_lease_expires_at IS NOT NULL)
    );

CREATE OR REPLACE FUNCTION attune.enforce_audit_intent_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
    expected_producer text;
    memberships integer;
BEGIN
    IF NEW.producer_kind IN ('dispatch_broker', 'channel_broker', 'retention', 'export') THEN
        IF NEW.producer_kind = 'export' THEN
            IF NOT (
                pg_catalog.pg_has_role(session_user, 'attune_control_plane', 'MEMBER')
                OR pg_catalog.pg_has_role(session_user, 'attune_export', 'MEMBER')
                OR pg_catalog.pg_has_role(session_user, 'attune_export_cleanup', 'MEMBER')
            ) THEN
                RAISE EXCEPTION 'audit producer identity does not match intent' USING ERRCODE = '42501';
            END IF;
        ELSIF NOT pg_catalog.pg_has_role(
            session_user,
            CASE NEW.producer_kind
                WHEN 'dispatch_broker' THEN 'attune_dispatch_broker'
                WHEN 'channel_broker' THEN 'attune_channel_broker'
                ELSE 'attune_retention'
            END,
            'MEMBER'
        ) THEN
            RAISE EXCEPTION 'audit producer identity does not match intent' USING ERRCODE = '42501';
        END IF;
        RETURN NEW;
    END IF;
    memberships :=
        pg_catalog.pg_has_role(current_user, 'attune_control_plane', 'MEMBER')::integer
        + pg_catalog.pg_has_role(current_user, 'attune_worker', 'MEMBER')::integer
        + pg_catalog.pg_has_role(current_user, 'attune_secret_broker', 'MEMBER')::integer;
    IF memberships <> 1 THEN
        RAISE EXCEPTION 'audit producer identity is ambiguous or unauthorized' USING ERRCODE = '42501';
    END IF;
    IF pg_catalog.pg_has_role(current_user, 'attune_control_plane', 'MEMBER') THEN
        expected_producer := 'control_plane';
    ELSIF pg_catalog.pg_has_role(current_user, 'attune_worker', 'MEMBER') THEN
        expected_producer := 'worker';
    ELSE
        expected_producer := 'secret_broker';
    END IF;
    IF NEW.producer_kind <> expected_producer THEN
        RAISE EXCEPTION 'audit producer identity does not match intent' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END
$function$;

CREATE FUNCTION attune.claim_customer_export_attempt_cleanups(
    p_run_id uuid, p_batch_size integer
)
RETURNS TABLE (tenant_id uuid, export_id uuid, attempt_run_id uuid, object_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    IF NOT pg_catalog.pg_has_role(session_user, 'attune_export_cleanup', 'MEMBER') THEN
        RAISE EXCEPTION 'export cleanup caller is unauthorized' USING ERRCODE = '42501';
    END IF;
    IF p_run_id IS NULL OR p_batch_size IS NULL OR p_batch_size NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'invalid export cleanup claim' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY
    WITH candidates AS MATERIALIZED (
        SELECT attempt.tenant_id, attempt.export_id, attempt.run_id
          FROM attune.export_object_attempts AS attempt
          JOIN attune.export_jobs AS job
            ON job.tenant_id = attempt.tenant_id AND job.id = attempt.export_id
         WHERE attempt.cleanup_pending AND attempt.object_ref IS NOT NULL
           AND attempt.created_at <= clock_timestamp() - interval '15 minutes'
           AND (attempt.cleanup_lease_expires_at IS NULL
                OR attempt.cleanup_lease_expires_at <= clock_timestamp())
           AND NOT (job.state = 'running' AND job.lease_run_id = attempt.run_id
                    AND job.lease_expires_at > clock_timestamp())
           AND NOT (job.state = 'ready' AND job.object_ref = attempt.object_ref)
         ORDER BY attempt.created_at, attempt.export_id, attempt.run_id
         LIMIT p_batch_size
         FOR UPDATE OF attempt SKIP LOCKED
    ), claimed AS (
        UPDATE attune.export_object_attempts AS attempt
           SET cleanup_lease_run_id = p_run_id,
               cleanup_lease_expires_at = clock_timestamp() + interval '5 minutes'
          FROM candidates
         WHERE attempt.tenant_id = candidates.tenant_id
           AND attempt.export_id = candidates.export_id
           AND attempt.run_id = candidates.run_id
        RETURNING attempt.tenant_id, attempt.export_id, attempt.run_id, attempt.object_ref
    )
    SELECT claimed.tenant_id, claimed.export_id, claimed.run_id, claimed.object_ref
      FROM claimed ORDER BY claimed.tenant_id, claimed.export_id, claimed.run_id;
END
$function$;

CREATE FUNCTION attune.complete_customer_export_attempt_cleanup(
    p_export_id uuid, p_attempt_run_id uuid, p_cleanup_run_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_attempt record;
BEGIN
    IF NOT pg_catalog.pg_has_role(session_user, 'attune_export_cleanup', 'MEMBER') THEN
        RAISE EXCEPTION 'export cleanup caller is unauthorized' USING ERRCODE = '42501';
    END IF;
    IF p_export_id IS NULL OR p_attempt_run_id IS NULL OR p_cleanup_run_id IS NULL THEN
        RAISE EXCEPTION 'invalid export cleanup completion' USING ERRCODE = '22023';
    END IF;
    UPDATE attune.export_object_attempts AS attempt
       SET cleanup_pending = false, cleaned_at = clock_timestamp(),
           cleanup_lease_run_id = NULL, cleanup_lease_expires_at = NULL
     WHERE attempt.export_id = p_export_id AND attempt.run_id = p_attempt_run_id
       AND attempt.cleanup_pending
       AND attempt.cleanup_lease_run_id = p_cleanup_run_id
       AND attempt.cleanup_lease_expires_at > clock_timestamp()
    RETURNING attempt.tenant_id, attempt.export_id INTO v_attempt;
    IF NOT FOUND THEN
        IF EXISTS (
            SELECT 1 FROM attune.export_object_attempts AS attempt
             WHERE attempt.export_id = p_export_id AND attempt.run_id = p_attempt_run_id
               AND NOT attempt.cleanup_pending AND attempt.cleaned_at IS NOT NULL
        ) THEN
            RETURN false;
        END IF;
        RAISE EXCEPTION 'active export cleanup claim is required' USING ERRCODE = '42501';
    END IF;
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type,
        action, outcome, target_type, target_ref_hash, metadata
    ) VALUES (
        v_attempt.tenant_id, 'export',
        attune_ext.digest(pg_catalog.convert_to(
            'export-attempt-cleaned-v1:' || p_export_id::text || ':' || p_attempt_run_id::text,
            'UTF8'), 'sha256'),
        'system', 'export.attempt.cleaned', 'observed', 'export_job',
        attune_ext.digest(pg_catalog.convert_to(p_export_id::text, 'UTF8'), 'sha256'),
        pg_catalog.jsonb_build_object('records', 1)
    ) ON CONFLICT (tenant_id, idempotency_key) DO NOTHING;
    RETURN true;
END
$function$;

DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format('GRANT attune_export_cleanup_coordinator TO %I', current_user);
END
$grant_owner$;
GRANT USAGE, CREATE ON SCHEMA attune TO attune_export_cleanup_coordinator;
GRANT USAGE ON SCHEMA attune_ext TO attune_export_cleanup_coordinator;
GRANT SELECT, UPDATE ON attune.export_object_attempts TO attune_export_cleanup_coordinator;
GRANT SELECT ON attune.export_jobs TO attune_export_cleanup_coordinator;
GRANT SELECT, INSERT ON attune.audit_intents TO attune_export_cleanup_coordinator;
ALTER FUNCTION attune.claim_customer_export_attempt_cleanups(uuid, integer)
OWNER TO attune_export_cleanup_coordinator;
ALTER FUNCTION attune.complete_customer_export_attempt_cleanup(uuid, uuid, uuid)
OWNER TO attune_export_cleanup_coordinator;
REVOKE CREATE ON SCHEMA attune FROM attune_export_cleanup_coordinator;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format('REVOKE attune_export_cleanup_coordinator FROM %I', current_user);
END
$revoke_owner$;
REVOKE ALL ON FUNCTION
    attune.claim_customer_export_attempt_cleanups(uuid, integer),
    attune.complete_customer_export_attempt_cleanup(uuid, uuid, uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.claim_customer_export_attempt_cleanups(uuid, integer),
    attune.complete_customer_export_attempt_cleanup(uuid, uuid, uuid)
TO attune_export_cleanup;
GRANT USAGE ON SCHEMA attune TO attune_export_cleanup;
