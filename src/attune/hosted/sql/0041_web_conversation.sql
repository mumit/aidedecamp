-- Web conversation surface: the authenticated Attune session itself is the
-- route. No installation, preference, or destination ceremony exists for
-- 'web' -- an ordinary session, an active policy, and an active Google
-- connector are the same authority the executor demands elsewhere. The
-- control plane calls attune.accept_web_owner_message directly (there is no
-- channel broker for this surface), so the dispatch/audit producer-identity
-- triggers are widened along the same two techniques already used for other
-- control-plane-invoked, dedicated-executor-owned functions:
--   * dispatch_intents keeps its existing 'ingress' producer_kind, and the
--     'ingress' session_user check (attune.enforce_dispatch_intent_insert)
--     is widened to accept attune_control_plane in addition to
--     attune_channel_broker -- exactly how 0033 widened the audit 'export'
--     branch to accept more than one legitimate session identity.
--   * audit_intents gains a new producer_kind, 'channel_message', with its
--     own session_user check requiring attune_control_plane -- exactly how
--     0029 introduced the 'export' producer_kind for a SECURITY DEFINER
--     function owned by a dedicated executor role but invoked directly by
--     the control plane's own session.
-- Both dispatch and audit end up owned by a new attune_web_message_executor
-- role (mirrors attune_channel_message_executor), never attune_control_plane
-- itself, so conversations/conversation_turns/jobs/provider_events stay
-- reachable only through this validated function, not through any direct
-- table grant to the control plane's ordinary session.

DO $roles$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'attune_web_message_executor'
    ) THEN
        CREATE ROLE attune_web_message_executor
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
    END IF;
END
$roles$;

ALTER TABLE attune.installations
DROP CONSTRAINT installations_provider_check;
ALTER TABLE attune.installations
ADD CONSTRAINT installations_provider_check
CHECK (provider IN ('google', 'slack', 'web'));

ALTER TABLE attune.provider_events
DROP CONSTRAINT provider_events_provider_check;
ALTER TABLE attune.provider_events
ADD CONSTRAINT provider_events_provider_check
CHECK (provider IN ('google', 'slack', 'web'));

ALTER TABLE attune.audit_intents
DROP CONSTRAINT audit_intents_producer_kind_check;
ALTER TABLE attune.audit_intents
ADD CONSTRAINT audit_intents_producer_kind_check CHECK (producer_kind IN (
    'control_plane', 'worker', 'secret_broker', 'dispatch_broker',
    'channel_broker', 'retention', 'export', 'channel_message'
));

CREATE OR REPLACE FUNCTION attune.enforce_dispatch_intent_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
    expected_producer text;
BEGIN
    IF NEW.producer_kind = 'ingress' THEN
        IF NOT (
            pg_catalog.pg_has_role(session_user, 'attune_channel_broker', 'MEMBER')
            OR pg_catalog.pg_has_role(session_user, 'attune_control_plane', 'MEMBER')
        ) THEN
            RAISE EXCEPTION 'dispatch producer identity does not match intent'
                USING ERRCODE = '42501';
        END IF;
    ELSIF pg_catalog.pg_has_role(
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
    IF NEW.producer_kind <> 'ingress'
       AND (expected_producer IS NULL OR NEW.producer_kind <> expected_producer) THEN
        RAISE EXCEPTION 'dispatch producer identity does not match intent'
            USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM attune.jobs AS job
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

CREATE OR REPLACE FUNCTION attune.enforce_audit_intent_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
    expected_producer text;
    memberships integer;
BEGIN
    IF NEW.producer_kind IN (
        'dispatch_broker', 'channel_broker', 'retention', 'export',
        'channel_message'
    ) THEN
        IF NEW.producer_kind = 'export' THEN
            IF NOT (
                pg_catalog.pg_has_role(session_user, 'attune_control_plane', 'MEMBER')
                OR pg_catalog.pg_has_role(session_user, 'attune_export', 'MEMBER')
                OR pg_catalog.pg_has_role(session_user, 'attune_export_cleanup', 'MEMBER')
            ) THEN
                RAISE EXCEPTION 'audit producer identity does not match intent'
                    USING ERRCODE = '42501';
            END IF;
        ELSIF NEW.producer_kind = 'channel_message' THEN
            IF NOT pg_catalog.pg_has_role(
                session_user, 'attune_control_plane', 'MEMBER'
            ) THEN
                RAISE EXCEPTION 'audit producer identity does not match intent'
                    USING ERRCODE = '42501';
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

-- No read-grant migration is needed for the polling GET route: 0002 already
-- grants attune_control_plane SELECT (and, incidentally, INSERT/UPDATE it
-- does not use here) on attune.conversations and attune.conversation_turns,
-- so the control plane's ordinary role can already select its own tenant's
-- conversations and turns under RLS. The turns-after-sequence-N and
-- pending-flag queries run as plain SELECTs from Python; no SQL read helper
-- is required.

CREATE FUNCTION attune.accept_web_owner_message(
    p_principal_id uuid,
    p_session_id uuid,
    p_message_text text
)
RETURNS TABLE (
    dispatch_intent_id uuid,
    pre_audit_intent_id uuid,
    conversation_id uuid,
    user_sequence bigint,
    accepted_new boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_tenant_id uuid := attune.current_tenant_id();
    v_principal_ref_hash bytea;
    v_installation_id uuid;
    v_provider_event_id uuid;
    v_conversation_id uuid;
    v_sequence bigint;
    v_job_id uuid;
    v_dispatch_id uuid;
    v_audit_id uuid;
    v_job_key bytea;
    v_audit_key bytea;
    v_dedup_key bytea;
    v_conversation_ref_hash bytea;
BEGIN
    IF p_principal_id IS NULL OR p_session_id IS NULL
       OR p_message_text IS NULL
       OR length(p_message_text) NOT BETWEEN 1 AND 8000
    THEN
        RAISE EXCEPTION 'web message is invalid' USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_tenant_id::text || ':' || p_principal_id::text || ':web-conversation',
        0
    ));

    IF NOT EXISTS (
        SELECT 1
          FROM attune.identity_sessions session
          JOIN attune.principals principal
            ON principal.tenant_id = session.tenant_id
           AND principal.id = session.principal_id
          JOIN attune.tenants tenant ON tenant.id = session.tenant_id
         WHERE session.tenant_id = v_tenant_id
           AND session.id = p_session_id
           AND session.principal_id = p_principal_id
           AND session.revoked_at IS NULL
           AND session.expires_at > clock_timestamp()
           AND principal.status = 'active'
           AND tenant.status = 'active'
           AND EXISTS (
               SELECT 1 FROM attune.policies policy
                WHERE policy.tenant_id = v_tenant_id AND policy.active
           )
           AND EXISTS (
               SELECT 1 FROM attune.connectors connector
                WHERE connector.tenant_id = v_tenant_id
                  AND connector.principal_id = p_principal_id
                  AND connector.provider = 'google'
                  AND connector.status = 'active'
           )
    ) THEN
        RAISE EXCEPTION 'web conversation owner is unavailable' USING ERRCODE = 'P0002';
    END IF;

    v_principal_ref_hash := attune_ext.digest(
        pg_catalog.convert_to(p_principal_id::text, 'UTF8'), 'sha256'
    );

    INSERT INTO attune.installations (
        tenant_id, provider, kind, external_ref_hash, metadata
    ) VALUES (
        v_tenant_id, 'web', 'channel', v_principal_ref_hash,
        jsonb_build_object('schema_version', 1, 'surface', 'web')
    )
    ON CONFLICT (tenant_id, provider, external_ref_hash) DO UPDATE
       SET updated_at = clock_timestamp()
    RETURNING id INTO v_installation_id;

    INSERT INTO attune.conversations (
        tenant_id, installation_id, principal_id, surface, external_ref_hash
    ) VALUES (
        v_tenant_id, v_installation_id, p_principal_id, 'web', v_principal_ref_hash
    )
    ON CONFLICT (tenant_id, surface, external_ref_hash) DO UPDATE
       SET updated_at = clock_timestamp()
    RETURNING id INTO v_conversation_id;
    PERFORM 1 FROM attune.conversations
     WHERE tenant_id = v_tenant_id AND id = v_conversation_id FOR UPDATE;
    SELECT COALESCE(max(turn.sequence), 0) + 1 INTO v_sequence
      FROM attune.conversation_turns turn
     WHERE turn.tenant_id = v_tenant_id
       AND turn.conversation_id = v_conversation_id;

    v_conversation_ref_hash := attune_ext.digest(
        pg_catalog.convert_to(v_conversation_id::text, 'UTF8'), 'sha256'
    );
    v_job_key := attune_ext.digest(
        pg_catalog.convert_to(
            'web-conversation-job-v1:' || v_conversation_id::text || ':'
                || v_sequence::text,
            'UTF8'
        ), 'sha256'
    );
    v_audit_key := attune_ext.digest(
        pg_catalog.convert_to(
            'web-conversation-audit-v1:' || v_conversation_id::text || ':'
                || v_sequence::text,
            'UTF8'
        ), 'sha256'
    );
    v_dedup_key := attune_ext.digest(
        pg_catalog.convert_to(
            'web-message-v1:' || v_conversation_id::text || ':' || v_sequence::text,
            'UTF8'
        ), 'sha256'
    );

    SELECT job.id, intent.id, audit.id
      INTO v_job_id, v_dispatch_id, v_audit_id
      FROM attune.jobs job
      JOIN attune.dispatch_intents intent
        ON intent.tenant_id = job.tenant_id AND intent.job_id = job.id
      JOIN attune.audit_intents audit
        ON audit.tenant_id = job.tenant_id AND audit.idempotency_key = v_audit_key
     WHERE job.tenant_id = v_tenant_id AND job.idempotency_key = v_job_key;
    IF FOUND THEN
        RETURN QUERY SELECT v_dispatch_id, v_audit_id, v_conversation_id,
                            v_sequence, false;
        RETURN;
    END IF;

    INSERT INTO attune.provider_events (
        tenant_id, installation_id, provider, kind, deduplication_key, signal
    ) VALUES (
        v_tenant_id, v_installation_id, 'web', 'web.message', v_dedup_key,
        jsonb_build_object(
            'schema_version', 1, 'conversation_id', v_conversation_id,
            'principal_id', p_principal_id
        )
    ) RETURNING id INTO v_provider_event_id;

    INSERT INTO attune.conversation_turns (
        tenant_id, conversation_id, sequence, actor_type, content, provenance
    ) VALUES (
        v_tenant_id, v_conversation_id, v_sequence, 'user', p_message_text,
        jsonb_build_object(
            'schema_version', 1, 'surface', 'web',
            'provider_event_id', v_provider_event_id
        )
    );
    UPDATE attune.provider_events
       SET signal = signal || jsonb_build_object('user_sequence', v_sequence)
     WHERE tenant_id = v_tenant_id AND id = v_provider_event_id;

    INSERT INTO attune.jobs (
        tenant_id, kind, idempotency_key, capability, payload
    ) VALUES (
        v_tenant_id, 'channel.web.converse', v_job_key,
        'assistant.conversation.read',
        jsonb_build_object(
            'schema_version', 1, 'provider_event_id', v_provider_event_id,
            'conversation_id', v_conversation_id, 'user_sequence', v_sequence
        )
    ) RETURNING id INTO v_job_id;
    INSERT INTO attune.dispatch_intents (
        tenant_id, job_id, producer_kind, purpose, capability, expires_at
    ) VALUES (
        v_tenant_id, v_job_id, 'ingress', 'channel.web.converse',
        'assistant.conversation.read', clock_timestamp() + interval '10 minutes'
    ) RETURNING id INTO v_dispatch_id;
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, actor_ref_hash,
        action, outcome, target_type, target_ref_hash, metadata
    ) VALUES (
        v_tenant_id, 'channel_message', v_audit_key, 'principal',
        v_principal_ref_hash, 'hosted.channels.web.message.accept', 'allowed',
        'conversation', v_conversation_ref_hash,
        jsonb_build_object(
            'schema_version', 1, 'content_stored', true, 'user_sequence', v_sequence
        )
    ) RETURNING id INTO v_audit_id;
    RETURN QUERY SELECT v_dispatch_id, v_audit_id, v_conversation_id, v_sequence,
                        true;
END
$function$;

REVOKE ALL ON FUNCTION
    attune.accept_web_owner_message(uuid, uuid, text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.accept_web_owner_message(uuid, uuid, text)
TO attune_control_plane;

DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'GRANT attune_web_message_executor TO %I', current_user
    );
END
$grant_owner$;
GRANT USAGE, CREATE ON SCHEMA attune TO attune_web_message_executor;
GRANT USAGE ON SCHEMA attune_ext TO attune_web_message_executor;
GRANT EXECUTE ON FUNCTION attune.current_tenant_id() TO attune_web_message_executor;
GRANT SELECT ON attune.tenants, attune.principals, attune.identity_sessions,
    attune.connectors, attune.policies
TO attune_web_message_executor;
GRANT SELECT, INSERT, UPDATE ON attune.installations
TO attune_web_message_executor;
GRANT SELECT, INSERT, UPDATE ON attune.provider_events, attune.conversations,
    attune.conversation_turns, attune.jobs, attune.dispatch_intents,
    attune.audit_intents
TO attune_web_message_executor;
ALTER FUNCTION attune.accept_web_owner_message(uuid, uuid, text)
OWNER TO attune_web_message_executor;
REVOKE CREATE ON SCHEMA attune FROM attune_web_message_executor;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'REVOKE attune_web_message_executor FROM %I', current_user
    );
END
$revoke_owner$;

ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON FUNCTIONS FROM PUBLIC;
