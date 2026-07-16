DO $roles$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'attune_channel_message_executor'
    ) THEN
        CREATE ROLE attune_channel_message_executor
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
    END IF;
END
$roles$;

CREATE OR REPLACE FUNCTION attune.enforce_dispatch_intent_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
    expected_producer text;
BEGIN
    IF NEW.producer_kind = 'ingress' THEN
        IF NOT pg_catalog.pg_has_role(
            session_user, 'attune_channel_broker', 'MEMBER'
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

CREATE FUNCTION attune.accept_google_chat_owner_message(
    p_installation_ref_hash bytea,
    p_actor_ref_hash bytea,
    p_destination_ref_hash bytea,
    p_message_ref_hash bytea,
    p_message_text text
)
RETURNS TABLE (
    dispatch_intent_id uuid,
    pre_audit_intent_id uuid,
    accepted_new boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_matches integer := 0;
    v_tenant_id uuid;
    v_principal_id uuid;
    v_installation_id uuid;
    v_destination_id uuid;
    v_provider_event_id uuid;
    v_conversation_id uuid;
    v_sequence bigint;
    v_job_id uuid;
    v_dispatch_id uuid;
    v_audit_id uuid;
    v_job_key bytea;
    v_audit_key bytea;
    candidate record;
BEGIN
    IF p_installation_ref_hash IS NULL
       OR octet_length(p_installation_ref_hash) <> 32
       OR p_actor_ref_hash IS NULL OR octet_length(p_actor_ref_hash) <> 32
       OR p_destination_ref_hash IS NULL
       OR octet_length(p_destination_ref_hash) <> 32
       OR p_message_ref_hash IS NULL OR octet_length(p_message_ref_hash) <> 32
       OR p_message_text IS NULL OR length(p_message_text) NOT BETWEEN 1 AND 8000
    THEN
        RAISE EXCEPTION 'Google Chat message is invalid' USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        encode(p_message_ref_hash, 'hex'), 0
    ));
    FOR candidate IN
        SELECT destination.tenant_id, destination.owner_principal_id,
               destination.installation_id, destination.id AS destination_id
          FROM attune.hosted_channel_destinations destination
          JOIN attune.installations installation
            ON installation.tenant_id = destination.tenant_id
           AND installation.id = destination.installation_id
          JOIN attune.tenants tenant ON tenant.id = destination.tenant_id
          JOIN attune.principals principal
            ON principal.tenant_id = destination.tenant_id
           AND principal.id = destination.owner_principal_id
          JOIN attune.hosted_channel_preferences preference
            ON preference.tenant_id = destination.tenant_id
           AND preference.owner_principal_id = destination.owner_principal_id
         WHERE destination.provider = 'google_chat'
           AND destination.visibility = 'owner_dm'
           AND destination.status = 'active'
           AND destination.delivery_verified_at IS NOT NULL
           AND destination.route_version = 1
           AND destination.installation_ref_hash = p_installation_ref_hash
           AND destination.actor_ref_hash = p_actor_ref_hash
           AND destination.destination_ref_hash = p_destination_ref_hash
           AND installation.provider = 'google'
           AND installation.kind = 'channel'
           AND installation.status = 'active'
           AND installation.external_ref_hash = p_installation_ref_hash
           AND tenant.status = 'active' AND principal.status = 'active'
           AND 'google_chat' = ANY(preference.interaction_channels)
           AND EXISTS (
               SELECT 1 FROM attune.connectors connector
                WHERE connector.tenant_id = destination.tenant_id
                  AND connector.principal_id = destination.owner_principal_id
                  AND connector.provider = 'google'
                  AND connector.status = 'active'
           )
           AND EXISTS (
               SELECT 1 FROM attune.policies policy
                WHERE policy.tenant_id = destination.tenant_id
                  AND policy.active
           )
           AND EXISTS (
               SELECT 1 FROM attune.hosted_channel_routes route
                WHERE route.tenant_id = destination.tenant_id
                  AND route.destination_id = destination.id
                  AND route.format_version = 1
           )
         LIMIT 2
    LOOP
        v_matches := v_matches + 1;
        v_tenant_id := candidate.tenant_id;
        v_principal_id := candidate.owner_principal_id;
        v_installation_id := candidate.installation_id;
        v_destination_id := candidate.destination_id;
    END LOOP;
    IF v_matches <> 1 THEN
        RAISE EXCEPTION 'Google Chat owner destination is unavailable'
            USING ERRCODE = 'P0002';
    END IF;

    v_job_key := attune_ext.digest(
        pg_catalog.convert_to(
            'google-chat-conversation-job-v1:' || encode(p_message_ref_hash, 'hex'),
            'UTF8'
        ), 'sha256'
    );
    v_audit_key := attune_ext.digest(
        pg_catalog.convert_to(
            'google-chat-conversation-audit-v1:' || encode(p_message_ref_hash, 'hex'),
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
        RETURN QUERY SELECT v_dispatch_id, v_audit_id, false;
        RETURN;
    END IF;

    INSERT INTO attune.provider_events (
        tenant_id, installation_id, provider, kind, deduplication_key, signal
    ) VALUES (
        v_tenant_id, v_installation_id, 'google', 'google_chat.message',
        p_message_ref_hash,
        jsonb_build_object(
            'schema_version', 1, 'destination_id', v_destination_id,
            'principal_id', v_principal_id
        )
    ) RETURNING id INTO v_provider_event_id;

    INSERT INTO attune.conversations (
        tenant_id, installation_id, principal_id, surface, external_ref_hash
    ) VALUES (
        v_tenant_id, v_installation_id, v_principal_id, 'google_chat',
        attune_ext.digest(p_actor_ref_hash || p_destination_ref_hash, 'sha256')
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
    INSERT INTO attune.conversation_turns (
        tenant_id, conversation_id, sequence, actor_type, content, provenance
    ) VALUES (
        v_tenant_id, v_conversation_id, v_sequence, 'user', p_message_text,
        jsonb_build_object(
            'schema_version', 1, 'surface', 'google_chat',
            'provider_event_id', v_provider_event_id
        )
    );
    UPDATE attune.provider_events
       SET signal = signal || jsonb_build_object(
           'conversation_id', v_conversation_id, 'user_sequence', v_sequence
       )
     WHERE tenant_id = v_tenant_id AND id = v_provider_event_id;

    INSERT INTO attune.jobs (
        tenant_id, kind, idempotency_key, capability, payload
    ) VALUES (
        v_tenant_id, 'channel.google_chat.converse', v_job_key,
        'assistant.conversation.read',
        jsonb_build_object(
            'schema_version', 1, 'provider_event_id', v_provider_event_id,
            'conversation_id', v_conversation_id, 'user_sequence', v_sequence,
            'destination_id', v_destination_id
        )
    ) RETURNING id INTO v_job_id;
    INSERT INTO attune.dispatch_intents (
        tenant_id, job_id, producer_kind, purpose, capability, expires_at
    ) VALUES (
        v_tenant_id, v_job_id, 'ingress', 'channel.google_chat.converse',
        'assistant.conversation.read', clock_timestamp() + interval '10 minutes'
    ) RETURNING id INTO v_dispatch_id;
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, actor_ref_hash,
        action, outcome, target_type, target_ref_hash, metadata
    ) VALUES (
        v_tenant_id, 'channel_broker', v_audit_key, 'provider', p_actor_ref_hash,
        'hosted.channels.google_chat.message.accept', 'allowed',
        'provider_message', p_message_ref_hash,
        jsonb_build_object('schema_version', 1, 'content_stored', true)
    ) RETURNING id INTO v_audit_id;
    RETURN QUERY SELECT v_dispatch_id, v_audit_id, true;
END
$function$;

REVOKE ALL ON FUNCTION attune.accept_google_chat_owner_message(
    bytea,bytea,bytea,bytea,text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION attune.accept_google_chat_owner_message(
    bytea,bytea,bytea,bytea,text
) TO attune_channel_broker;

DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'GRANT attune_channel_message_executor TO %I', current_user
    );
END
$grant_owner$;
GRANT USAGE, CREATE ON SCHEMA attune TO attune_channel_message_executor;
GRANT USAGE ON SCHEMA attune_ext TO attune_channel_message_executor;
GRANT SELECT ON attune.tenants, attune.principals, attune.installations,
    attune.connectors, attune.policies, attune.hosted_channel_preferences,
    attune.hosted_channel_destinations, attune.hosted_channel_routes
TO attune_channel_message_executor;
GRANT SELECT, INSERT, UPDATE ON attune.provider_events, attune.conversations,
    attune.conversation_turns, attune.jobs, attune.dispatch_intents,
    attune.audit_intents
TO attune_channel_message_executor;
ALTER FUNCTION attune.accept_google_chat_owner_message(
    bytea,bytea,bytea,bytea,text
) OWNER TO attune_channel_message_executor;
REVOKE CREATE ON SCHEMA attune FROM attune_channel_message_executor;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'REVOKE attune_channel_message_executor FROM %I', current_user
    );
END
$revoke_owner$;

ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON FUNCTIONS FROM PUBLIC;
