DO $roles$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'attune_dispatch_broker'
    ) THEN
        CREATE ROLE attune_dispatch_broker
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
END
$roles$;

CREATE TABLE attune.dispatch_intents (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    job_id uuid NOT NULL,
    delivery_id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    producer_kind text NOT NULL
        CHECK (producer_kind IN ('control_plane', 'ingress', 'worker')),
    purpose text NOT NULL CHECK (length(purpose) BETWEEN 1 AND 80),
    capability text NOT NULL CHECK (length(capability) BETWEEN 1 AND 120),
    state text NOT NULL DEFAULT 'requested'
        CHECK (state IN (
            'requested', 'leased', 'dispatched', 'failed', 'cancelled'
        )),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    expires_at timestamptz NOT NULL,
    lease_expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (id),
    UNIQUE (tenant_id, job_id),
    UNIQUE (delivery_id),
    FOREIGN KEY (tenant_id, job_id) REFERENCES attune.jobs(tenant_id, id),
    CHECK (expires_at > created_at),
    CHECK ((state = 'leased') = (lease_expires_at IS NOT NULL))
);

CREATE INDEX dispatch_intents_recovery
    ON attune.dispatch_intents (state, lease_expires_at, expires_at);

ALTER TABLE attune.dispatch_intents ENABLE ROW LEVEL SECURITY;
ALTER TABLE attune.dispatch_intents FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON attune.dispatch_intents
USING (tenant_id = attune.current_tenant_id())
WITH CHECK (tenant_id = attune.current_tenant_id());

REVOKE ALL ON attune.dispatch_intents FROM PUBLIC;
GRANT SELECT, INSERT ON attune.dispatch_intents
TO attune_control_plane, attune_worker;

CREATE FUNCTION attune.enforce_dispatch_intent_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
    expected_producer text;
BEGIN
    IF pg_catalog.pg_has_role(
        current_user, 'attune_control_plane', 'MEMBER'
    ) AND NOT pg_catalog.pg_has_role(
        current_user, 'attune_worker', 'MEMBER'
    ) THEN
        expected_producer := 'control_plane';
    ELSIF pg_catalog.pg_has_role(
        current_user, 'attune_worker', 'MEMBER'
    ) AND NOT pg_catalog.pg_has_role(
        current_user, 'attune_control_plane', 'MEMBER'
    ) THEN
        expected_producer := 'worker';
    ELSE
        expected_producer := NULL;
    END IF;
    IF expected_producer IS NULL OR NEW.producer_kind <> expected_producer THEN
        RAISE EXCEPTION 'dispatch producer identity does not match intent'
            USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM attune.jobs AS job
        WHERE job.tenant_id = NEW.tenant_id
          AND job.id = NEW.job_id
          AND job.kind = NEW.purpose
          AND job.capability = NEW.capability
          AND job.state = 'queued'
    ) THEN
        RAISE EXCEPTION 'dispatch intent does not match a queued canonical job'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER dispatch_intent_insert_guard
BEFORE INSERT ON attune.dispatch_intents
FOR EACH ROW EXECUTE FUNCTION attune.enforce_dispatch_intent_insert();

CREATE FUNCTION attune.lease_dispatch_intent(
    p_intent_id uuid,
    p_producer_kind text,
    p_lease_seconds integer
)
RETURNS TABLE (
    intent_id uuid,
    tenant_id uuid,
    job_id uuid,
    delivery_id uuid,
    purpose text,
    capability text,
    intent_state text,
    attempts integer,
    expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    IF p_producer_kind NOT IN ('control_plane', 'ingress', 'worker') THEN
        RAISE EXCEPTION 'invalid dispatch producer kind' USING ERRCODE = '22023';
    END IF;
    IF p_lease_seconds < 1 OR p_lease_seconds > 300 THEN
        RAISE EXCEPTION 'invalid dispatch lease duration' USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH leased AS (
        UPDATE attune.dispatch_intents AS intent
           SET state = 'leased',
               attempts = intent.attempts + 1,
               lease_expires_at = clock_timestamp()
                   + (p_lease_seconds * interval '1 second'),
               updated_at = clock_timestamp()
         WHERE intent.id = p_intent_id
           AND intent.producer_kind = p_producer_kind
           AND intent.expires_at > clock_timestamp()
           AND (
               intent.state = 'requested'
               OR (
                   intent.state = 'leased'
                   AND intent.lease_expires_at <= clock_timestamp()
               )
           )
           AND EXISTS (
               SELECT 1
               FROM attune.jobs AS job
               WHERE job.tenant_id = intent.tenant_id
                 AND job.id = intent.job_id
                 AND job.kind = intent.purpose
                 AND job.capability = intent.capability
                 AND job.state = 'queued'
           )
        RETURNING intent.id, intent.tenant_id, intent.job_id, intent.delivery_id,
                  intent.purpose, intent.capability, intent.state,
                  intent.attempts, intent.expires_at
    )
    SELECT * FROM leased
    UNION ALL
    SELECT intent.id, intent.tenant_id, intent.job_id, intent.delivery_id,
           intent.purpose, intent.capability, intent.state,
           intent.attempts, intent.expires_at
      FROM attune.dispatch_intents AS intent
     WHERE intent.id = p_intent_id
       AND intent.producer_kind = p_producer_kind
       AND intent.state = 'dispatched'
       AND NOT EXISTS (SELECT 1 FROM leased)
    LIMIT 1;
END
$function$;

CREATE FUNCTION attune.finalize_dispatch_intent(
    p_intent_id uuid,
    p_producer_kind text,
    p_outcome text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    changed boolean;
BEGIN
    IF p_outcome NOT IN ('dispatched', 'failed', 'cancelled') THEN
        RAISE EXCEPTION 'invalid dispatch outcome' USING ERRCODE = '22023';
    END IF;

    UPDATE attune.dispatch_intents AS intent
       SET state = p_outcome,
           lease_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE intent.id = p_intent_id
       AND intent.producer_kind = p_producer_kind
       AND intent.state = 'leased';
    changed := FOUND;
    IF changed THEN
        RETURN true;
    END IF;
    RETURN EXISTS (
        SELECT 1
        FROM attune.dispatch_intents AS intent
        WHERE intent.id = p_intent_id
          AND intent.producer_kind = p_producer_kind
          AND intent.state = p_outcome
    );
END
$function$;

REVOKE ALL ON FUNCTION
    attune.enforce_dispatch_intent_insert() FROM PUBLIC;
REVOKE ALL ON FUNCTION
    attune.lease_dispatch_intent(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION
    attune.finalize_dispatch_intent(uuid, text, text) FROM PUBLIC;
GRANT USAGE ON SCHEMA attune TO attune_dispatch_broker;
GRANT EXECUTE ON FUNCTION
    attune.lease_dispatch_intent(uuid, text, integer)
TO attune_dispatch_broker;
GRANT EXECUTE ON FUNCTION
    attune.finalize_dispatch_intent(uuid, text, text)
TO attune_dispatch_broker;
