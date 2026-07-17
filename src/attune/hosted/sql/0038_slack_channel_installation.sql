-- Slack owner-DM installation, delivery, conversation, and lifecycle.
-- Mirrors the Google Chat channel functions (0022-0027) with Slack proofs:
-- a one-use OAuth state replaces the link code, and the broker retains an
-- encrypted bot token in addition to the encrypted destination route.

CREATE TABLE attune.hosted_channel_credentials (
    tenant_id uuid NOT NULL,
    destination_id uuid NOT NULL,
    purpose text NOT NULL CHECK (purpose = 'slack_bot_token'),
    ciphertext bytea NOT NULL,
    nonce bytea NOT NULL CHECK (octet_length(nonce) = 12),
    wrapped_dek bytea NOT NULL,
    key_resource text NOT NULL CHECK (length(key_resource) BETWEEN 20 AND 1024),
    format_version integer NOT NULL DEFAULT 1 CHECK (format_version = 1),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, destination_id, purpose),
    FOREIGN KEY (tenant_id, destination_id)
        REFERENCES attune.hosted_channel_destinations(tenant_id, id)
        ON DELETE CASCADE
);

ALTER TABLE attune.hosted_channel_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE attune.hosted_channel_credentials FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON attune.hosted_channel_credentials
USING (tenant_id = attune.current_tenant_id())
WITH CHECK (tenant_id = attune.current_tenant_id());
REVOKE ALL ON attune.hosted_channel_credentials FROM PUBLIC;

CREATE FUNCTION attune.claim_slack_install(
    p_state_hash bytea, p_claim_hash bytea, p_claim_expires_at timestamptz
)
RETURNS TABLE (
    transaction_id uuid, tenant_id uuid, owner_principal_id uuid,
    pre_audit_intent_id uuid
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_setup attune.hosted_channel_setup_transactions%ROWTYPE;
    v_audit_id uuid;
BEGIN
    IF p_state_hash IS NULL OR octet_length(p_state_hash) <> 32
       OR p_claim_hash IS NULL OR octet_length(p_claim_hash) <> 32
       OR p_claim_expires_at IS NULL
       OR p_claim_expires_at <= clock_timestamp()
       OR p_claim_expires_at > clock_timestamp() + interval '60 seconds' THEN
        RAISE EXCEPTION 'invalid Slack install claim' USING ERRCODE = '22023';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        encode(p_state_hash, 'hex'), 0
    ));
    UPDATE attune.hosted_channel_setup_transactions setup
       SET state = CASE WHEN setup.expires_at <= clock_timestamp()
                        THEN 'expired' ELSE 'pending' END,
           claim_hash = NULL, claim_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE setup.provider = 'slack' AND setup.mechanism = 'oauth'
       AND setup.secret_hash = p_state_hash AND setup.state = 'claimed'
       AND setup.claim_expires_at <= clock_timestamp();

    SELECT setup.* INTO v_setup
      FROM attune.hosted_channel_setup_transactions setup
      JOIN attune.tenants tenant ON tenant.id = setup.tenant_id
      JOIN attune.principals principal
        ON principal.tenant_id = setup.tenant_id
       AND principal.id = setup.owner_principal_id
      JOIN attune.hosted_onboarding_states onboarding
        ON onboarding.tenant_id = setup.tenant_id
       AND onboarding.owner_principal_id = setup.owner_principal_id
      JOIN attune.hosted_channel_preferences preference
        ON preference.tenant_id = setup.tenant_id
       AND preference.owner_principal_id = setup.owner_principal_id
     WHERE setup.provider = 'slack' AND setup.mechanism = 'oauth'
       AND setup.secret_hash = p_state_hash AND setup.state = 'pending'
       AND setup.expires_at > clock_timestamp()
       AND tenant.status = 'active' AND principal.status = 'active'
       AND onboarding.channels_status IN ('authorized', 'applied')
       AND setup.preference_revision = preference.revision
       AND 'slack' = ANY(
           preference.interaction_channels || preference.brief_channels
       )
     FOR UPDATE OF setup;
    IF NOT FOUND OR p_claim_expires_at > v_setup.expires_at THEN
        RAISE EXCEPTION 'Slack install is unavailable' USING ERRCODE = 'P0002';
    END IF;

    UPDATE attune.hosted_channel_setup_transactions AS claimed_setup
       SET state = 'claimed', claim_hash = p_claim_hash,
           claim_expires_at = p_claim_expires_at, updated_at = clock_timestamp()
     WHERE claimed_setup.tenant_id = v_setup.tenant_id
       AND claimed_setup.id = v_setup.id;
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, action, outcome,
        target_type, target_ref_hash, metadata
    ) VALUES (
        v_setup.tenant_id, 'channel_broker',
        p_claim_hash,
        'provider', 'hosted.channels.slack.install', 'allowed',
        'channel_setup', p_state_hash,
        jsonb_build_object('schema_version', 1)
    ) RETURNING id INTO v_audit_id;
    RETURN QUERY SELECT v_setup.id, v_setup.tenant_id,
                        v_setup.owner_principal_id, v_audit_id;
END
$function$;

CREATE FUNCTION attune.release_slack_install_claim(
    p_state_hash bytea, p_claim_hash bytea
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_changed boolean;
BEGIN
    IF p_state_hash IS NULL OR octet_length(p_state_hash) <> 32
       OR p_claim_hash IS NULL OR octet_length(p_claim_hash) <> 32 THEN
        RAISE EXCEPTION 'invalid Slack install claim' USING ERRCODE = '22023';
    END IF;
    UPDATE attune.hosted_channel_setup_transactions setup
       SET state = CASE WHEN setup.expires_at <= clock_timestamp()
                        THEN 'expired' ELSE 'pending' END,
           claim_hash = NULL, claim_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE setup.provider = 'slack' AND setup.mechanism = 'oauth'
       AND setup.secret_hash = p_state_hash AND setup.state = 'claimed'
       AND setup.claim_hash = p_claim_hash;
    v_changed := FOUND;
    RETURN v_changed;
END
$function$;

CREATE FUNCTION attune.resolve_slack_install_destination(
    p_state_hash bytea, p_claim_hash bytea, p_candidate_id uuid
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_destination_id uuid;
BEGIN
    IF p_state_hash IS NULL OR octet_length(p_state_hash) <> 32
       OR p_claim_hash IS NULL OR octet_length(p_claim_hash) <> 32
       OR p_candidate_id IS NULL THEN
        RAISE EXCEPTION 'invalid Slack destination resolution'
            USING ERRCODE = '22023';
    END IF;
    SELECT destination.id INTO v_destination_id
      FROM attune.hosted_channel_setup_transactions setup
      LEFT JOIN attune.hosted_channel_destinations destination
        ON destination.tenant_id = setup.tenant_id
       AND destination.owner_principal_id = setup.owner_principal_id
       AND destination.provider = 'slack'
       AND destination.status = 'revoked'
     WHERE setup.provider = 'slack' AND setup.mechanism = 'oauth'
       AND setup.secret_hash = p_state_hash AND setup.state = 'claimed'
       AND setup.claim_hash = p_claim_hash
       AND setup.claim_expires_at > clock_timestamp()
       AND setup.expires_at > clock_timestamp();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Slack install is unavailable' USING ERRCODE = 'P0002';
    END IF;
    RETURN COALESCE(v_destination_id, p_candidate_id);
END
$function$;

CREATE FUNCTION attune.consume_slack_install(
    p_state_hash bytea, p_claim_hash bytea,
    p_owner_tenant_id uuid, p_owner_principal_id uuid,
    p_installation_ref_hash bytea, p_actor_ref_hash bytea,
    p_destination_ref_hash bytea, p_destination_id uuid,
    p_route_ciphertext bytea, p_route_nonce bytea, p_route_wrapped_dek bytea,
    p_route_key_resource text, p_route_format_version integer,
    p_token_ciphertext bytea, p_token_nonce bytea, p_token_wrapped_dek bytea,
    p_token_key_resource text, p_token_format_version integer
)
RETURNS TABLE (
    tenant_id uuid, owner_principal_id uuid, installation_id uuid,
    destination_id uuid, destination_status text, outcome_audit_intent_id uuid
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_setup attune.hosted_channel_setup_transactions%ROWTYPE;
    v_installation_id uuid;
    v_audit_id uuid;
    v_existing attune.hosted_channel_destinations%ROWTYPE;
BEGIN
    IF p_state_hash IS NULL OR octet_length(p_state_hash) <> 32
       OR p_claim_hash IS NULL OR octet_length(p_claim_hash) <> 32
       OR p_owner_tenant_id IS NULL OR p_owner_principal_id IS NULL
       OR p_installation_ref_hash IS NULL
       OR octet_length(p_installation_ref_hash) <> 32
       OR p_actor_ref_hash IS NULL OR octet_length(p_actor_ref_hash) <> 32
       OR p_destination_ref_hash IS NULL
       OR octet_length(p_destination_ref_hash) <> 32
       OR p_destination_id IS NULL
       OR p_route_ciphertext IS NULL OR length(p_route_ciphertext) < 17
       OR p_route_nonce IS NULL OR octet_length(p_route_nonce) <> 12
       OR p_route_wrapped_dek IS NULL OR length(p_route_wrapped_dek) < 1
       OR p_route_key_resource IS NULL
       OR length(p_route_key_resource) NOT BETWEEN 20 AND 1024
       OR p_route_format_version <> 1
       OR p_token_ciphertext IS NULL OR length(p_token_ciphertext) < 17
       OR p_token_nonce IS NULL OR octet_length(p_token_nonce) <> 12
       OR p_token_wrapped_dek IS NULL OR length(p_token_wrapped_dek) < 1
       OR p_token_key_resource IS NULL
       OR length(p_token_key_resource) NOT BETWEEN 20 AND 1024
       OR p_token_format_version <> 1 THEN
        RAISE EXCEPTION 'invalid Slack install consumption' USING ERRCODE = '22023';
    END IF;
    SELECT setup.* INTO v_setup
      FROM attune.hosted_channel_setup_transactions setup
      JOIN attune.tenants tenant ON tenant.id = setup.tenant_id
      JOIN attune.principals principal
        ON principal.tenant_id = setup.tenant_id
       AND principal.id = setup.owner_principal_id
      JOIN attune.hosted_channel_preferences preference
        ON preference.tenant_id = setup.tenant_id
       AND preference.owner_principal_id = setup.owner_principal_id
     WHERE setup.provider = 'slack' AND setup.mechanism = 'oauth'
       AND setup.secret_hash = p_state_hash AND setup.state = 'claimed'
       AND setup.claim_hash = p_claim_hash
       AND setup.claim_expires_at > clock_timestamp()
       AND setup.expires_at > clock_timestamp()
       AND setup.tenant_id = p_owner_tenant_id
       AND setup.owner_principal_id = p_owner_principal_id
       AND tenant.status = 'active' AND principal.status = 'active'
       AND setup.preference_revision = preference.revision
       AND 'slack' = ANY(
           preference.interaction_channels || preference.brief_channels
       )
     FOR UPDATE OF setup;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Slack install is unavailable' USING ERRCODE = 'P0002';
    END IF;
    SELECT destination.* INTO v_existing
      FROM attune.hosted_channel_destinations destination
     WHERE destination.tenant_id = v_setup.tenant_id
       AND destination.provider = 'slack'
     FOR UPDATE;
    IF FOUND AND (
        v_existing.owner_principal_id <> v_setup.owner_principal_id
        OR v_existing.status <> 'revoked'
    ) THEN
        RAISE EXCEPTION 'channel destination requires replacement ceremony'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO attune.installations (
        tenant_id, provider, kind, external_ref_hash, metadata
    ) VALUES (
        v_setup.tenant_id, 'slack', 'channel', p_installation_ref_hash,
        jsonb_build_object('surface', 'slack', 'schema_version', 1)
    ) RETURNING id INTO v_installation_id;
    IF v_existing.id IS NULL THEN
      INSERT INTO attune.hosted_channel_destinations (
        tenant_id, id, owner_principal_id, installation_id, provider,
        installation_ref_hash, actor_ref_hash, destination_ref_hash,
        ingress_verified_at, route_version
      ) VALUES (
        v_setup.tenant_id, p_destination_id, v_setup.owner_principal_id,
        v_installation_id, 'slack', p_installation_ref_hash,
        p_actor_ref_hash, p_destination_ref_hash, clock_timestamp(), 1
      );
    ELSE
      p_destination_id := v_existing.id;
      DELETE FROM attune.hosted_channel_routes route
       WHERE route.tenant_id = v_setup.tenant_id
         AND route.destination_id = v_existing.id;
      DELETE FROM attune.hosted_channel_credentials credential
       WHERE credential.tenant_id = v_setup.tenant_id
         AND credential.destination_id = v_existing.id;
      UPDATE attune.hosted_channel_destinations destination
         SET status = 'pending_test', installation_id = v_installation_id,
             installation_ref_hash = p_installation_ref_hash,
             actor_ref_hash = p_actor_ref_hash,
             destination_ref_hash = p_destination_ref_hash,
             ingress_verified_at = clock_timestamp(),
             delivery_verified_at = NULL, route_version = 1,
             delivery_claim_hash = NULL, delivery_claim_expires_at = NULL,
             version = destination.version + 1, updated_at = clock_timestamp()
       WHERE destination.tenant_id = v_setup.tenant_id
         AND destination.id = v_existing.id;
    END IF;
    INSERT INTO attune.hosted_channel_routes (
        tenant_id, destination_id, ciphertext, nonce, wrapped_dek,
        key_resource, format_version
    ) VALUES (
        v_setup.tenant_id, p_destination_id, p_route_ciphertext, p_route_nonce,
        p_route_wrapped_dek, p_route_key_resource, p_route_format_version
    );
    INSERT INTO attune.hosted_channel_credentials (
        tenant_id, destination_id, purpose, ciphertext, nonce, wrapped_dek,
        key_resource, format_version
    ) VALUES (
        v_setup.tenant_id, p_destination_id, 'slack_bot_token',
        p_token_ciphertext, p_token_nonce, p_token_wrapped_dek,
        p_token_key_resource, p_token_format_version
    );
    UPDATE attune.hosted_channel_setup_transactions AS consumed_setup
       SET state = 'consumed', consumed_at = clock_timestamp(),
           claim_hash = NULL, claim_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE consumed_setup.tenant_id = v_setup.tenant_id
       AND consumed_setup.id = v_setup.id;
    UPDATE attune.hosted_onboarding_states onboarding
       SET channels_status = 'applied', revision = revision + 1,
           updated_at = clock_timestamp()
     WHERE onboarding.tenant_id = v_setup.tenant_id
       AND onboarding.owner_principal_id = v_setup.owner_principal_id
       AND onboarding.channels_status = 'authorized';
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, actor_ref_hash,
        action, outcome, target_type, target_ref_hash, metadata
    ) VALUES (
        v_setup.tenant_id, 'channel_broker',
        set_byte(p_claim_hash, 0, get_byte(p_claim_hash, 0) # 1),
        'provider', p_actor_ref_hash, 'hosted.channels.slack.install',
        'observed', 'owner_dm', p_destination_ref_hash,
        jsonb_build_object('schema_version', 1)
    ) RETURNING id INTO v_audit_id;
    RETURN QUERY SELECT v_setup.tenant_id, v_setup.owner_principal_id,
                        v_installation_id, p_destination_id,
                        'pending_test'::text, v_audit_id;
END
$function$;

CREATE FUNCTION attune.claim_slack_delivery_test(
    p_destination_id uuid, p_claim_hash bytea, p_claim_expires_at timestamptz
)
RETURNS TABLE (
    tenant_id uuid, owner_principal_id uuid,
    route_ciphertext bytea, route_nonce bytea, route_wrapped_dek bytea,
    route_key_resource text, route_format_version integer,
    token_ciphertext bytea, token_nonce bytea, token_wrapped_dek bytea,
    token_key_resource text, token_format_version integer,
    pre_audit_intent_id uuid
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_destination attune.hosted_channel_destinations%ROWTYPE;
    v_route attune.hosted_channel_routes%ROWTYPE;
    v_credential attune.hosted_channel_credentials%ROWTYPE;
    v_audit_id uuid;
BEGIN
    IF p_destination_id IS NULL OR p_claim_hash IS NULL
       OR octet_length(p_claim_hash) <> 32 OR p_claim_expires_at IS NULL
       OR p_claim_expires_at <= clock_timestamp()
       OR p_claim_expires_at > clock_timestamp() + interval '60 seconds' THEN
        RAISE EXCEPTION 'invalid channel delivery claim' USING ERRCODE = '22023';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(p_destination_id::text, 0));
    UPDATE attune.hosted_channel_destinations destination
       SET delivery_claim_hash = NULL, delivery_claim_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE destination.id = p_destination_id
       AND destination.status = 'pending_test'
       AND destination.delivery_claim_expires_at <= clock_timestamp();
    SELECT destination.* INTO v_destination
      FROM attune.hosted_channel_destinations destination
      JOIN attune.tenants tenant ON tenant.id = destination.tenant_id
      JOIN attune.principals principal
        ON principal.tenant_id = destination.tenant_id
       AND principal.id = destination.owner_principal_id
      JOIN attune.hosted_channel_preferences preference
        ON preference.tenant_id = destination.tenant_id
       AND preference.owner_principal_id = destination.owner_principal_id
     WHERE destination.id = p_destination_id
       AND destination.provider = 'slack'
       AND destination.visibility = 'owner_dm'
       AND destination.status = 'pending_test'
       AND destination.delivery_claim_hash IS NULL
       AND tenant.status = 'active' AND principal.status = 'active'
       AND 'slack' = ANY(preference.interaction_channels || preference.brief_channels)
     FOR UPDATE OF destination;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'channel delivery test is unavailable' USING ERRCODE = 'P0002';
    END IF;
    SELECT route.* INTO STRICT v_route
      FROM attune.hosted_channel_routes route
     WHERE route.tenant_id = v_destination.tenant_id
       AND route.destination_id = v_destination.id;
    SELECT credential.* INTO STRICT v_credential
      FROM attune.hosted_channel_credentials credential
     WHERE credential.tenant_id = v_destination.tenant_id
       AND credential.destination_id = v_destination.id
       AND credential.purpose = 'slack_bot_token';
    UPDATE attune.hosted_channel_destinations destination
       SET delivery_claim_hash = p_claim_hash,
           delivery_claim_expires_at = p_claim_expires_at,
           updated_at = clock_timestamp()
     WHERE destination.tenant_id = v_destination.tenant_id
       AND destination.id = v_destination.id;
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, action, outcome,
        target_type, target_ref_hash, metadata
    ) VALUES (
        v_destination.tenant_id, 'channel_broker', p_claim_hash,
        'principal', 'hosted.channels.slack.delivery_test', 'allowed',
        'owner_dm', v_destination.destination_ref_hash,
        jsonb_build_object('schema_version', 1, 'content_profile', 'fixed_connection_test_v1')
    ) RETURNING id INTO v_audit_id;
    RETURN QUERY SELECT v_destination.tenant_id, v_destination.owner_principal_id,
                        v_route.ciphertext, v_route.nonce, v_route.wrapped_dek,
                        v_route.key_resource, v_route.format_version,
                        v_credential.ciphertext, v_credential.nonce,
                        v_credential.wrapped_dek, v_credential.key_resource,
                        v_credential.format_version, v_audit_id;
END
$function$;

CREATE FUNCTION attune.complete_slack_delivery_test(
    p_destination_id uuid, p_claim_hash bytea, p_succeeded boolean
)
RETURNS TABLE (destination_status text, outcome_audit_intent_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_destination attune.hosted_channel_destinations%ROWTYPE;
    v_audit_id uuid;
    v_all_active boolean;
BEGIN
    IF p_destination_id IS NULL OR p_claim_hash IS NULL
       OR octet_length(p_claim_hash) <> 32 OR p_succeeded IS NULL THEN
        RAISE EXCEPTION 'invalid channel delivery completion' USING ERRCODE = '22023';
    END IF;
    SELECT destination.* INTO v_destination
      FROM attune.hosted_channel_destinations destination
     WHERE destination.id = p_destination_id
       AND destination.provider = 'slack'
       AND destination.status = 'pending_test'
       AND destination.delivery_claim_hash = p_claim_hash
       AND destination.delivery_claim_expires_at > clock_timestamp()
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'channel delivery test is unavailable' USING ERRCODE = 'P0002';
    END IF;
    UPDATE attune.hosted_channel_destinations destination
       SET status = CASE WHEN p_succeeded THEN 'active' ELSE 'pending_test' END,
           delivery_verified_at = CASE WHEN p_succeeded THEN clock_timestamp() ELSE NULL END,
           delivery_claim_hash = NULL, delivery_claim_expires_at = NULL,
           version = CASE WHEN p_succeeded THEN destination.version + 1 ELSE destination.version END,
           updated_at = clock_timestamp()
     WHERE destination.tenant_id = v_destination.tenant_id
       AND destination.id = v_destination.id;
    IF p_succeeded THEN
        SELECT NOT EXISTS (
            SELECT selected.provider
              FROM (
                    SELECT DISTINCT unnest(
                        preference.interaction_channels || preference.brief_channels
                    ) AS provider
                      FROM attune.hosted_channel_preferences preference
                     WHERE preference.tenant_id = v_destination.tenant_id
                       AND preference.owner_principal_id = v_destination.owner_principal_id
              ) selected
             WHERE NOT EXISTS (
                    SELECT 1 FROM attune.hosted_channel_destinations destination
                     WHERE destination.tenant_id = v_destination.tenant_id
                       AND destination.owner_principal_id = v_destination.owner_principal_id
                       AND destination.provider = selected.provider
                       AND destination.status = 'active'
             )
        ) INTO v_all_active;
        IF v_all_active THEN
            UPDATE attune.hosted_onboarding_states onboarding
               SET channels_status = 'validated', revision = revision + 1,
                   updated_at = clock_timestamp()
             WHERE onboarding.tenant_id = v_destination.tenant_id
               AND onboarding.owner_principal_id = v_destination.owner_principal_id
               AND onboarding.channels_status IN ('authorized', 'applied');
        END IF;
    END IF;
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, action, outcome,
        target_type, target_ref_hash, metadata
    ) VALUES (
        v_destination.tenant_id, 'channel_broker',
        set_byte(p_claim_hash, 0, get_byte(p_claim_hash, 0) # 1),
        'principal', 'hosted.channels.slack.delivery_test',
        CASE WHEN p_succeeded THEN 'observed' ELSE 'failed' END,
        'owner_dm', v_destination.destination_ref_hash,
        jsonb_build_object('schema_version', 1, 'content_profile', 'fixed_connection_test_v1')
    ) RETURNING id INTO v_audit_id;
    RETURN QUERY SELECT CASE WHEN p_succeeded THEN 'active' ELSE 'pending_test' END,
                        v_audit_id;
END
$function$;

CREATE FUNCTION attune.accept_slack_owner_message(
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
        RAISE EXCEPTION 'Slack message is invalid' USING ERRCODE = '22023';
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
         WHERE destination.provider = 'slack'
           AND destination.visibility = 'owner_dm'
           AND destination.status = 'active'
           AND destination.delivery_verified_at IS NOT NULL
           AND destination.route_version = 1
           AND destination.installation_ref_hash = p_installation_ref_hash
           AND destination.actor_ref_hash = p_actor_ref_hash
           AND destination.destination_ref_hash = p_destination_ref_hash
           AND installation.provider = 'slack'
           AND installation.kind = 'channel'
           AND installation.status = 'active'
           AND installation.external_ref_hash = p_installation_ref_hash
           AND tenant.status = 'active' AND principal.status = 'active'
           AND 'slack' = ANY(preference.interaction_channels)
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
           AND EXISTS (
               SELECT 1 FROM attune.hosted_channel_credentials credential
                WHERE credential.tenant_id = destination.tenant_id
                  AND credential.destination_id = destination.id
                  AND credential.purpose = 'slack_bot_token'
                  AND credential.format_version = 1
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
        RAISE EXCEPTION 'Slack owner destination is unavailable'
            USING ERRCODE = 'P0002';
    END IF;

    v_job_key := attune_ext.digest(
        pg_catalog.convert_to(
            'slack-conversation-job-v1:' || encode(p_message_ref_hash, 'hex'),
            'UTF8'
        ), 'sha256'
    );
    v_audit_key := attune_ext.digest(
        pg_catalog.convert_to(
            'slack-conversation-audit-v1:' || encode(p_message_ref_hash, 'hex'),
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
        v_tenant_id, v_installation_id, 'slack', 'slack.message',
        p_message_ref_hash,
        jsonb_build_object(
            'schema_version', 1, 'destination_id', v_destination_id,
            'principal_id', v_principal_id
        )
    ) RETURNING id INTO v_provider_event_id;

    INSERT INTO attune.conversations (
        tenant_id, installation_id, principal_id, surface, external_ref_hash
    ) VALUES (
        v_tenant_id, v_installation_id, v_principal_id, 'slack',
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
            'schema_version', 1, 'surface', 'slack',
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
        v_tenant_id, 'channel.slack.converse', v_job_key,
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
        v_tenant_id, v_job_id, 'ingress', 'channel.slack.converse',
        'assistant.conversation.read', clock_timestamp() + interval '10 minutes'
    ) RETURNING id INTO v_dispatch_id;
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, actor_ref_hash,
        action, outcome, target_type, target_ref_hash, metadata
    ) VALUES (
        v_tenant_id, 'channel_broker', v_audit_key, 'provider', p_actor_ref_hash,
        'hosted.channels.slack.message.accept', 'allowed',
        'provider_message', p_message_ref_hash,
        jsonb_build_object('schema_version', 1, 'content_stored', true)
    ) RETURNING id INTO v_audit_id;
    RETURN QUERY SELECT v_dispatch_id, v_audit_id, true;
END
$function$;

CREATE FUNCTION attune.claim_slack_conversation_delivery(
    p_destination_id uuid, p_job_id uuid, p_claim_hash bytea,
    p_claim_expires_at timestamptz
)
RETURNS TABLE (
    tenant_id uuid,
    route_ciphertext bytea, route_nonce bytea, route_wrapped_dek bytea,
    route_key_resource text, route_format_version integer,
    token_ciphertext bytea, token_nonce bytea, token_wrapped_dek bytea,
    token_key_resource text, token_format_version integer,
    reply_text text, pre_audit_intent_id uuid, already_delivered boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_tenant_id uuid;
    v_route attune.hosted_channel_routes%ROWTYPE;
    v_credential attune.hosted_channel_credentials%ROWTYPE;
    v_reply text;
    v_delivery attune.hosted_channel_deliveries%ROWTYPE;
    v_audit_id uuid;
    v_audit_key bytea;
    v_matches integer := 0;
    v_delivery_exists boolean := false;
    candidate record;
BEGIN
    IF p_destination_id IS NULL OR p_job_id IS NULL OR p_claim_hash IS NULL
       OR octet_length(p_claim_hash) <> 32 OR p_claim_expires_at IS NULL
       OR p_claim_expires_at <= clock_timestamp()
       OR p_claim_expires_at > clock_timestamp() + interval '60 seconds' THEN
        RAISE EXCEPTION 'invalid conversation delivery claim'
            USING ERRCODE = '22023';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(p_job_id::text, 0));
    SELECT delivery.* INTO v_delivery
      FROM attune.hosted_channel_deliveries delivery
     WHERE delivery.job_id = p_job_id FOR UPDATE;
    v_delivery_exists := FOUND;
    IF FOUND AND v_delivery.destination_id <> p_destination_id THEN
        RAISE EXCEPTION 'conversation delivery destination changed'
            USING ERRCODE = '23514';
    END IF;
    IF FOUND AND v_delivery.state = 'delivered' THEN
        RETURN QUERY SELECT v_delivery.tenant_id,
            NULL::bytea, NULL::bytea, NULL::bytea, NULL::text, NULL::integer,
            NULL::bytea, NULL::bytea, NULL::bytea, NULL::text, NULL::integer,
            NULL::text, NULL::uuid, true;
        RETURN;
    END IF;
    IF FOUND AND v_delivery.state = 'claimed'
       AND v_delivery.claim_expires_at > clock_timestamp() THEN
        RAISE EXCEPTION 'conversation delivery is already claimed'
            USING ERRCODE = '55P03';
    END IF;

    FOR candidate IN
        SELECT job.tenant_id, route.*, credential.ciphertext AS credential_ciphertext,
               credential.nonce AS credential_nonce,
               credential.wrapped_dek AS credential_wrapped_dek,
               credential.key_resource AS credential_key_resource,
               credential.format_version AS credential_format_version,
               turn.content
          FROM attune.jobs job
          JOIN attune.hosted_channel_destinations destination
            ON destination.tenant_id = job.tenant_id
           AND destination.id = p_destination_id
          JOIN attune.hosted_channel_routes route
            ON route.tenant_id = destination.tenant_id
           AND route.destination_id = destination.id
          JOIN attune.hosted_channel_credentials credential
            ON credential.tenant_id = destination.tenant_id
           AND credential.destination_id = destination.id
           AND credential.purpose = 'slack_bot_token'
          JOIN attune.tenants tenant ON tenant.id = job.tenant_id
          JOIN attune.principals principal
            ON principal.tenant_id = job.tenant_id
           AND principal.id = destination.owner_principal_id
          JOIN attune.hosted_channel_preferences preference
            ON preference.tenant_id = job.tenant_id
           AND preference.owner_principal_id = destination.owner_principal_id
          JOIN attune.conversation_turns turn
            ON turn.tenant_id = job.tenant_id
           AND turn.conversation_id = (job.payload->>'conversation_id')::uuid
           AND turn.actor_type = 'assistant'
           AND turn.provenance->>'job_id' = job.id::text
         WHERE job.id = p_job_id AND job.kind = 'channel.slack.converse'
           AND job.capability = 'assistant.conversation.read'
           AND job.state = 'leased'
           AND job.payload->>'destination_id' = p_destination_id::text
           AND destination.provider = 'slack'
           AND destination.visibility = 'owner_dm'
           AND destination.status = 'active'
           AND destination.delivery_verified_at IS NOT NULL
           AND destination.route_version = 1
           AND tenant.status = 'active' AND principal.status = 'active'
           AND 'slack' = ANY(preference.interaction_channels)
           AND EXISTS (
               SELECT 1 FROM attune.policies policy
                WHERE policy.tenant_id = job.tenant_id AND policy.active
           )
         LIMIT 2
    LOOP
        v_matches := v_matches + 1;
        v_tenant_id := candidate.tenant_id;
        v_route.tenant_id := candidate.tenant_id;
        v_route.destination_id := candidate.destination_id;
        v_route.ciphertext := candidate.ciphertext;
        v_route.nonce := candidate.nonce;
        v_route.wrapped_dek := candidate.wrapped_dek;
        v_route.key_resource := candidate.key_resource;
        v_route.format_version := candidate.format_version;
        v_credential.ciphertext := candidate.credential_ciphertext;
        v_credential.nonce := candidate.credential_nonce;
        v_credential.wrapped_dek := candidate.credential_wrapped_dek;
        v_credential.key_resource := candidate.credential_key_resource;
        v_credential.format_version := candidate.credential_format_version;
        v_reply := candidate.content;
    END LOOP;
    IF v_matches <> 1 OR length(v_reply) NOT BETWEEN 1 AND 8000 THEN
        RAISE EXCEPTION 'canonical conversation delivery is unavailable'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_delivery_exists THEN
        UPDATE attune.hosted_channel_deliveries delivery
           SET state = 'claimed', claim_hash = p_claim_hash,
               claim_expires_at = p_claim_expires_at,
               provider_message_ref_hash = NULL, delivered_at = NULL,
               updated_at = clock_timestamp()
         WHERE delivery.tenant_id = v_tenant_id AND delivery.job_id = p_job_id;
    ELSE
        INSERT INTO attune.hosted_channel_deliveries (
            tenant_id, job_id, destination_id, state, claim_hash, claim_expires_at
        ) VALUES (
            v_tenant_id, p_job_id, p_destination_id, 'claimed', p_claim_hash,
            p_claim_expires_at
        );
    END IF;
    v_audit_key := p_claim_hash;
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, action, outcome,
        target_type, target_ref_hash, metadata
    ) VALUES (
        v_tenant_id, 'channel_broker', v_audit_key, 'assistant',
        'hosted.channels.slack.reply', 'allowed', 'owner_dm',
        (SELECT destination.destination_ref_hash
           FROM attune.hosted_channel_destinations destination
          WHERE destination.tenant_id = v_tenant_id
            AND destination.id = p_destination_id),
        jsonb_build_object('schema_version', 1, 'content_profile', 'conversation_reply_v1')
    ) ON CONFLICT ON CONSTRAINT audit_intents_tenant_id_idempotency_key_key
      DO NOTHING
      RETURNING id INTO v_audit_id;
    IF v_audit_id IS NULL THEN
        SELECT intent.id INTO STRICT v_audit_id FROM attune.audit_intents intent
         WHERE intent.tenant_id = v_tenant_id
           AND intent.idempotency_key = v_audit_key;
    END IF;
    RETURN QUERY SELECT v_tenant_id,
        v_route.ciphertext, v_route.nonce, v_route.wrapped_dek,
        v_route.key_resource, v_route.format_version,
        v_credential.ciphertext, v_credential.nonce, v_credential.wrapped_dek,
        v_credential.key_resource, v_credential.format_version,
        v_reply, v_audit_id, false;
END
$function$;

CREATE FUNCTION attune.complete_slack_conversation_delivery(
    p_job_id uuid, p_claim_hash bytea, p_succeeded boolean,
    p_provider_message_ref_hash bytea
)
RETURNS TABLE (delivery_state text, outcome_audit_intent_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_delivery attune.hosted_channel_deliveries%ROWTYPE;
    v_destination_hash bytea;
    v_audit_key bytea;
    v_audit_id uuid;
BEGIN
    IF p_job_id IS NULL OR p_claim_hash IS NULL
       OR octet_length(p_claim_hash) <> 32 OR p_succeeded IS NULL
       OR (p_succeeded AND (p_provider_message_ref_hash IS NULL
           OR octet_length(p_provider_message_ref_hash) <> 32))
       OR (NOT p_succeeded AND p_provider_message_ref_hash IS NOT NULL) THEN
        RAISE EXCEPTION 'invalid conversation delivery completion'
            USING ERRCODE = '22023';
    END IF;
    SELECT delivery.* INTO v_delivery
      FROM attune.hosted_channel_deliveries delivery
      JOIN attune.jobs job
        ON job.tenant_id = delivery.tenant_id AND job.id = delivery.job_id
     WHERE delivery.job_id = p_job_id AND delivery.state = 'claimed'
       AND delivery.claim_hash = p_claim_hash
       AND delivery.claim_expires_at > clock_timestamp()
       AND job.kind = 'channel.slack.converse'
     FOR UPDATE OF delivery;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'conversation delivery claim is unavailable'
            USING ERRCODE = 'P0002';
    END IF;
    UPDATE attune.hosted_channel_deliveries delivery
       SET state = CASE WHEN p_succeeded THEN 'delivered' ELSE 'failed' END,
           claim_hash = NULL, claim_expires_at = NULL,
           provider_message_ref_hash = p_provider_message_ref_hash,
           delivered_at = CASE WHEN p_succeeded THEN clock_timestamp() ELSE NULL END,
           updated_at = clock_timestamp()
     WHERE delivery.tenant_id = v_delivery.tenant_id
       AND delivery.job_id = v_delivery.job_id;
    SELECT destination.destination_ref_hash INTO STRICT v_destination_hash
      FROM attune.hosted_channel_destinations destination
     WHERE destination.tenant_id = v_delivery.tenant_id
       AND destination.id = v_delivery.destination_id;
    v_audit_key := set_byte(
        p_claim_hash, 0,
        get_byte(p_claim_hash, 0) # CASE WHEN p_succeeded THEN 1 ELSE 2 END
    );
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, action, outcome,
        target_type, target_ref_hash, metadata
    ) VALUES (
        v_delivery.tenant_id, 'channel_broker', v_audit_key, 'assistant',
        'hosted.channels.slack.reply',
        CASE WHEN p_succeeded THEN 'observed' ELSE 'failed' END,
        'owner_dm', v_destination_hash,
        jsonb_build_object('schema_version', 1, 'content_profile', 'conversation_reply_v1')
    ) ON CONFLICT ON CONSTRAINT audit_intents_tenant_id_idempotency_key_key
      DO NOTHING
      RETURNING id INTO v_audit_id;
    IF v_audit_id IS NULL THEN
        SELECT intent.id INTO STRICT v_audit_id FROM attune.audit_intents intent
         WHERE intent.tenant_id = v_delivery.tenant_id
           AND intent.idempotency_key = v_audit_key;
    END IF;
    RETURN QUERY SELECT CASE WHEN p_succeeded THEN 'delivered' ELSE 'failed' END,
                        v_audit_id;
END
$function$;

CREATE FUNCTION attune.disconnect_hosted_channel_destination_v2(
    p_principal_id uuid, p_session_id uuid, p_provider text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_tenant_id uuid := attune.current_tenant_id();
    v_destination attune.hosted_channel_destinations%ROWTYPE;
BEGIN
    IF p_provider = 'google_chat' THEN
        RETURN attune.disconnect_hosted_channel_destination(
            p_principal_id, p_session_id, p_provider
        );
    END IF;
    IF p_principal_id IS NULL OR p_session_id IS NULL
       OR p_provider <> 'slack' THEN
        RAISE EXCEPTION 'channel disconnect request is invalid'
            USING ERRCODE = '22023';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_tenant_id::text || ':' || p_principal_id::text || ':' || p_provider
        || ':channel-lifecycle', 0
    ));
    IF NOT EXISTS (
        SELECT 1 FROM attune.identity_sessions session
        JOIN attune.principals principal
          ON principal.tenant_id = session.tenant_id
         AND principal.id = session.principal_id
        JOIN attune.tenants tenant ON tenant.id = session.tenant_id
         WHERE session.tenant_id = v_tenant_id
           AND session.id = p_session_id
           AND session.principal_id = p_principal_id
           AND session.revoked_at IS NULL
           AND session.expires_at > clock_timestamp()
           AND session.created_at >= clock_timestamp() - interval '10 minutes'
           AND principal.status = 'active' AND tenant.status = 'active'
    ) THEN
        RAISE EXCEPTION 'channel disconnect principal is unavailable'
            USING ERRCODE = '23514';
    END IF;
    SELECT destination.* INTO v_destination
      FROM attune.hosted_channel_destinations destination
     WHERE destination.tenant_id = v_tenant_id
       AND destination.owner_principal_id = p_principal_id
       AND destination.provider = p_provider
     FOR UPDATE;
    IF NOT FOUND OR v_destination.status = 'revoked' THEN
        RETURN false;
    END IF;

    UPDATE attune.hosted_channel_setup_transactions setup
       SET state = CASE WHEN setup.expires_at <= clock_timestamp()
                        THEN 'expired' ELSE 'cancelled' END,
           claim_hash = NULL, claim_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE setup.tenant_id = v_tenant_id
       AND setup.owner_principal_id = p_principal_id
       AND setup.provider = p_provider
       AND setup.state IN ('pending', 'claimed');
    DELETE FROM attune.hosted_channel_routes route
     WHERE route.tenant_id = v_tenant_id
       AND route.destination_id = v_destination.id;
    DELETE FROM attune.hosted_channel_credentials credential
     WHERE credential.tenant_id = v_tenant_id
       AND credential.destination_id = v_destination.id;
    UPDATE attune.hosted_channel_destinations destination
       SET status = 'revoked', delivery_verified_at = NULL,
           route_version = NULL, delivery_claim_hash = NULL,
           delivery_claim_expires_at = NULL, version = destination.version + 1,
           updated_at = clock_timestamp()
     WHERE destination.tenant_id = v_tenant_id
       AND destination.id = v_destination.id;
    UPDATE attune.installations installation
       SET status = 'revoked', updated_at = clock_timestamp()
     WHERE installation.tenant_id = v_tenant_id
       AND installation.id = v_destination.installation_id;
    UPDATE attune.hosted_onboarding_states onboarding
       SET channels_status = 'authorized', revision = onboarding.revision + 1,
           updated_at = clock_timestamp()
     WHERE onboarding.tenant_id = v_tenant_id
       AND onboarding.owner_principal_id = p_principal_id
       AND onboarding.channels_status IN ('applied', 'validated');
    RETURN true;
END
$function$;

REVOKE ALL ON FUNCTION
    attune.claim_slack_install(bytea,bytea,timestamptz),
    attune.release_slack_install_claim(bytea,bytea),
    attune.resolve_slack_install_destination(bytea,bytea,uuid),
    attune.consume_slack_install(bytea,bytea,uuid,uuid,bytea,bytea,bytea,uuid,bytea,bytea,bytea,text,integer,bytea,bytea,bytea,text,integer),
    attune.claim_slack_delivery_test(uuid,bytea,timestamptz),
    attune.complete_slack_delivery_test(uuid,bytea,boolean),
    attune.accept_slack_owner_message(bytea,bytea,bytea,bytea,text),
    attune.claim_slack_conversation_delivery(uuid,uuid,bytea,timestamptz),
    attune.complete_slack_conversation_delivery(uuid,bytea,boolean,bytea),
    attune.disconnect_hosted_channel_destination_v2(uuid,uuid,text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.claim_slack_install(bytea,bytea,timestamptz),
    attune.release_slack_install_claim(bytea,bytea),
    attune.resolve_slack_install_destination(bytea,bytea,uuid),
    attune.consume_slack_install(bytea,bytea,uuid,uuid,bytea,bytea,bytea,uuid,bytea,bytea,bytea,text,integer,bytea,bytea,bytea,text,integer),
    attune.claim_slack_delivery_test(uuid,bytea,timestamptz),
    attune.complete_slack_delivery_test(uuid,bytea,boolean),
    attune.accept_slack_owner_message(bytea,bytea,bytea,bytea,text),
    attune.claim_slack_conversation_delivery(uuid,uuid,bytea,timestamptz),
    attune.complete_slack_conversation_delivery(uuid,bytea,boolean,bytea)
TO attune_channel_broker;
GRANT EXECUTE ON FUNCTION
    attune.disconnect_hosted_channel_destination_v2(uuid,uuid,text)
TO attune_control_plane;

GRANT SELECT, INSERT, DELETE ON attune.hosted_channel_credentials
TO attune_channel_link_executor;
GRANT SELECT ON attune.hosted_channel_credentials
TO attune_channel_message_executor;
GRANT SELECT, DELETE ON attune.hosted_channel_credentials
TO attune_channel_lifecycle_executor;
GRANT DELETE ON attune.hosted_channel_routes
TO attune_channel_link_executor;

DO $grant_link_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'GRANT attune_channel_link_executor TO %I', current_user
    );
END
$grant_link_owner$;
GRANT CREATE ON SCHEMA attune TO attune_channel_link_executor;
ALTER FUNCTION attune.claim_slack_install(bytea,bytea,timestamptz)
OWNER TO attune_channel_link_executor;
ALTER FUNCTION attune.release_slack_install_claim(bytea,bytea)
OWNER TO attune_channel_link_executor;
ALTER FUNCTION attune.resolve_slack_install_destination(bytea,bytea,uuid)
OWNER TO attune_channel_link_executor;
ALTER FUNCTION attune.consume_slack_install(bytea,bytea,uuid,uuid,bytea,bytea,bytea,uuid,bytea,bytea,bytea,text,integer,bytea,bytea,bytea,text,integer)
OWNER TO attune_channel_link_executor;
ALTER FUNCTION attune.claim_slack_delivery_test(uuid,bytea,timestamptz)
OWNER TO attune_channel_link_executor;
ALTER FUNCTION attune.complete_slack_delivery_test(uuid,bytea,boolean)
OWNER TO attune_channel_link_executor;
ALTER FUNCTION attune.claim_slack_conversation_delivery(uuid,uuid,bytea,timestamptz)
OWNER TO attune_channel_link_executor;
ALTER FUNCTION attune.complete_slack_conversation_delivery(uuid,bytea,boolean,bytea)
OWNER TO attune_channel_link_executor;
REVOKE CREATE ON SCHEMA attune FROM attune_channel_link_executor;
DO $revoke_link_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'REVOKE attune_channel_link_executor FROM %I', current_user
    );
END
$revoke_link_owner$;

DO $grant_message_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'GRANT attune_channel_message_executor TO %I', current_user
    );
END
$grant_message_owner$;
GRANT CREATE ON SCHEMA attune TO attune_channel_message_executor;
ALTER FUNCTION attune.accept_slack_owner_message(bytea,bytea,bytea,bytea,text)
OWNER TO attune_channel_message_executor;
REVOKE CREATE ON SCHEMA attune FROM attune_channel_message_executor;
DO $revoke_message_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'REVOKE attune_channel_message_executor FROM %I', current_user
    );
END
$revoke_message_owner$;

DO $grant_lifecycle_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'GRANT attune_channel_lifecycle_executor TO %I', current_user
    );
END
$grant_lifecycle_owner$;
GRANT CREATE ON SCHEMA attune TO attune_channel_lifecycle_executor;
ALTER FUNCTION attune.disconnect_hosted_channel_destination_v2(uuid,uuid,text)
OWNER TO attune_channel_lifecycle_executor;
REVOKE CREATE ON SCHEMA attune FROM attune_channel_lifecycle_executor;
DO $revoke_lifecycle_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'REVOKE attune_channel_lifecycle_executor FROM %I', current_user
    );
END
$revoke_lifecycle_owner$;

ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON FUNCTIONS FROM PUBLIC;
