CREATE TABLE attune.audit_intents (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    producer_kind text NOT NULL CHECK (producer_kind IN (
        'control_plane', 'worker', 'secret_broker', 'dispatch_broker'
    )),
    idempotency_key bytea NOT NULL CHECK (octet_length(idempotency_key) = 32),
    actor_type text NOT NULL CHECK (length(actor_type) BETWEEN 1 AND 64),
    actor_ref_hash bytea CHECK (
        actor_ref_hash IS NULL OR octet_length(actor_ref_hash) = 32
    ),
    action text NOT NULL CHECK (length(action) BETWEEN 1 AND 120),
    outcome text NOT NULL CHECK (
        outcome IN ('allowed', 'denied', 'failed', 'observed')
    ),
    target_type text CHECK (
        target_type IS NULL OR length(target_type) BETWEEN 1 AND 64
    ),
    target_ref_hash bytea CHECK (
        target_ref_hash IS NULL OR octet_length(target_ref_hash) = 32
    ),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (
        jsonb_typeof(metadata) = 'object'
        AND pg_column_size(metadata) <= 16384
    ),
    state text NOT NULL DEFAULT 'requested'
        CHECK (state IN ('requested', 'written')),
    audit_event_id uuid,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    written_at timestamptz,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (id),
    UNIQUE (tenant_id, idempotency_key),
    FOREIGN KEY (tenant_id) REFERENCES attune.tenants(id),
    CHECK ((state = 'written') = (audit_event_id IS NOT NULL)),
    CHECK ((state = 'written') = (written_at IS NOT NULL))
);

CREATE INDEX audit_intents_pending
    ON attune.audit_intents (state, created_at) WHERE state = 'requested';

ALTER TABLE attune.audit_intents ENABLE ROW LEVEL SECURITY;
ALTER TABLE attune.audit_intents FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON attune.audit_intents
USING (tenant_id = attune.current_tenant_id())
WITH CHECK (tenant_id = attune.current_tenant_id());

REVOKE ALL ON attune.audit_intents FROM PUBLIC;
GRANT SELECT, INSERT ON attune.audit_intents
TO attune_control_plane, attune_worker, attune_secret_broker;

CREATE FUNCTION attune.enforce_audit_intent_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
    expected_producer text;
    memberships integer;
BEGIN
    -- The dispatch broker can only reach this trigger through the narrow
    -- SECURITY DEFINER request function, so authenticate its original login.
    IF NEW.producer_kind = 'dispatch_broker' THEN
        IF NOT pg_catalog.pg_has_role(
            session_user, 'attune_dispatch_broker', 'MEMBER'
        ) THEN
            RAISE EXCEPTION 'audit producer identity does not match intent'
                USING ERRCODE = '42501';
        END IF;
        RETURN NEW;
    END IF;
    memberships :=
        pg_catalog.pg_has_role(
            current_user, 'attune_control_plane', 'MEMBER'
        )::integer
        + pg_catalog.pg_has_role(
            current_user, 'attune_worker', 'MEMBER'
        )::integer
        + pg_catalog.pg_has_role(
            current_user, 'attune_secret_broker', 'MEMBER'
        )::integer;
    IF memberships <> 1 THEN
        RAISE EXCEPTION 'audit producer identity is ambiguous or unauthorized'
            USING ERRCODE = '42501';
    END IF;
    IF pg_catalog.pg_has_role(
        current_user, 'attune_control_plane', 'MEMBER'
    ) THEN
        expected_producer := 'control_plane';
    ELSIF pg_catalog.pg_has_role(
        current_user, 'attune_worker', 'MEMBER'
    ) THEN
        expected_producer := 'worker';
    ELSE
        expected_producer := 'secret_broker';
    END IF;
    IF NEW.producer_kind <> expected_producer THEN
        RAISE EXCEPTION 'audit producer identity does not match intent'
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER audit_intent_insert_guard
BEFORE INSERT ON attune.audit_intents
FOR EACH ROW EXECUTE FUNCTION attune.enforce_audit_intent_insert();

CREATE FUNCTION attune.request_dispatch_audit(
    p_dispatch_intent_id uuid,
    p_outcome text,
    p_error_code text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_tenant_id uuid;
    v_state text;
    v_audit_intent_id uuid;
    v_idempotency_key bytea;
BEGIN
    IF p_outcome NOT IN ('observed', 'failed') THEN
        RAISE EXCEPTION 'invalid dispatch audit outcome' USING ERRCODE = '22023';
    END IF;
    IF p_error_code IS NOT NULL
       AND length(p_error_code) NOT BETWEEN 1 AND 80 THEN
        RAISE EXCEPTION 'invalid dispatch audit error code'
            USING ERRCODE = '22023';
    END IF;

    SELECT intent.tenant_id, intent.state
      INTO v_tenant_id, v_state
      FROM attune.dispatch_intents AS intent
     WHERE intent.id = p_dispatch_intent_id;
    IF v_tenant_id IS NULL
       OR (p_outcome = 'observed' AND v_state <> 'dispatched')
       OR (p_outcome = 'failed' AND v_state NOT IN ('failed', 'cancelled')) THEN
        RETURN NULL;
    END IF;

    v_idempotency_key := attune_ext.digest(
        pg_catalog.convert_to(
            'dispatch-audit-v1:' || p_dispatch_intent_id::text || ':' || p_outcome,
            'UTF8'
        ),
        'sha256'
    );
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, action,
        outcome, target_type, target_ref_hash, metadata
    ) VALUES (
        v_tenant_id, 'dispatch_broker', v_idempotency_key, 'workload',
        'task.dispatch', p_outcome, 'dispatch_intent',
        attune_ext.digest(
            pg_catalog.convert_to(p_dispatch_intent_id::text, 'UTF8'), 'sha256'
        ),
        CASE
            WHEN p_error_code IS NULL THEN '{}'::jsonb
            ELSE pg_catalog.jsonb_build_object('error_code', p_error_code)
        END
    )
    ON CONFLICT (tenant_id, idempotency_key) DO UPDATE
       SET idempotency_key = EXCLUDED.idempotency_key
    RETURNING id INTO v_audit_intent_id;
    RETURN v_audit_intent_id;
END
$function$;

CREATE FUNCTION attune.write_audit_intent(p_audit_intent_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    intent attune.audit_intents%ROWTYPE;
    v_event_id uuid;
BEGIN
    SELECT * INTO intent
      FROM attune.audit_intents
     WHERE id = p_audit_intent_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    IF intent.state = 'written' THEN
        RETURN intent.audit_event_id;
    END IF;

    PERFORM pg_catalog.set_config(
        'attune.tenant_id', intent.tenant_id::text, true
    );
    v_event_id := attune.append_audit_event(
        intent.tenant_id, intent.actor_type, intent.actor_ref_hash,
        intent.action, intent.outcome, intent.target_type,
        intent.target_ref_hash, intent.metadata
    );
    UPDATE attune.audit_intents
       SET state = 'written', audit_event_id = v_event_id,
           written_at = clock_timestamp()
     WHERE tenant_id = intent.tenant_id AND id = intent.id;
    RETURN v_event_id;
END
$function$;

REVOKE ALL ON FUNCTION attune.enforce_audit_intent_insert() FROM PUBLIC;
REVOKE ALL ON FUNCTION
    attune.request_dispatch_audit(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION attune.write_audit_intent(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION
    attune.append_audit_event(uuid, text, bytea, text, text, text, bytea, jsonb)
FROM attune_audit_writer;
GRANT EXECUTE ON FUNCTION
    attune.request_dispatch_audit(uuid, text, text)
TO attune_dispatch_broker;
GRANT EXECUTE ON FUNCTION attune.write_audit_intent(uuid)
TO attune_audit_writer;
