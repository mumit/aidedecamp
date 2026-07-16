DO $roles$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
         WHERE rolname = 'attune_channel_lifecycle_executor'
    ) THEN
        CREATE ROLE attune_channel_lifecycle_executor
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
    END IF;
END
$roles$;

CREATE FUNCTION attune.disconnect_hosted_channel_destination(
    p_principal_id uuid, p_session_id uuid, p_provider text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_tenant_id uuid := attune.current_tenant_id();
    v_destination attune.hosted_channel_destinations%ROWTYPE;
BEGIN
    IF p_principal_id IS NULL OR p_session_id IS NULL
       OR p_provider <> 'google_chat' THEN
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

REVOKE ALL ON FUNCTION attune.disconnect_hosted_channel_destination(
    uuid,uuid,text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION attune.disconnect_hosted_channel_destination(
    uuid,uuid,text
) TO attune_control_plane;

DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'GRANT attune_channel_lifecycle_executor TO %I', current_user
    );
END
$grant_owner$;
GRANT USAGE, CREATE ON SCHEMA attune TO attune_channel_lifecycle_executor;
GRANT EXECUTE ON FUNCTION attune.current_tenant_id()
TO attune_channel_lifecycle_executor;
GRANT SELECT ON attune.tenants, attune.principals, attune.identity_sessions,
    attune.hosted_channel_destinations
TO attune_channel_lifecycle_executor;
GRANT SELECT, UPDATE ON attune.installations,
    attune.hosted_channel_setup_transactions, attune.hosted_onboarding_states
TO attune_channel_lifecycle_executor;
GRANT UPDATE ON attune.hosted_channel_destinations
TO attune_channel_lifecycle_executor;
GRANT SELECT, DELETE ON attune.hosted_channel_routes
TO attune_channel_lifecycle_executor;
ALTER FUNCTION attune.disconnect_hosted_channel_destination(uuid,uuid,text)
OWNER TO attune_channel_lifecycle_executor;
REVOKE CREATE ON SCHEMA attune FROM attune_channel_lifecycle_executor;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'REVOKE attune_channel_lifecycle_executor FROM %I', current_user
    );
END
$revoke_owner$;

CREATE OR REPLACE FUNCTION attune.consume_google_chat_link_v2(
    p_secret_hash bytea, p_claim_hash bytea,
    p_installation_ref_hash bytea, p_actor_ref_hash bytea,
    p_destination_ref_hash bytea, p_destination_id uuid,
    p_ciphertext bytea, p_nonce bytea, p_wrapped_dek bytea,
    p_key_resource text, p_format_version integer
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
    IF p_secret_hash IS NULL OR octet_length(p_secret_hash) <> 32
       OR p_claim_hash IS NULL OR octet_length(p_claim_hash) <> 32
       OR p_installation_ref_hash IS NULL OR octet_length(p_installation_ref_hash) <> 32
       OR p_actor_ref_hash IS NULL OR octet_length(p_actor_ref_hash) <> 32
       OR p_destination_ref_hash IS NULL OR octet_length(p_destination_ref_hash) <> 32
       OR p_destination_id IS NULL OR p_ciphertext IS NULL OR length(p_ciphertext) < 17
       OR p_nonce IS NULL OR octet_length(p_nonce) <> 12
       OR p_wrapped_dek IS NULL OR length(p_wrapped_dek) < 1
       OR p_key_resource IS NULL OR length(p_key_resource) NOT BETWEEN 20 AND 1024
       OR p_format_version <> 1 THEN
        RAISE EXCEPTION 'invalid channel link consumption' USING ERRCODE = '22023';
    END IF;
    SELECT setup.* INTO v_setup
      FROM attune.hosted_channel_setup_transactions setup
      JOIN attune.tenants tenant ON tenant.id = setup.tenant_id
      JOIN attune.principals principal
        ON principal.tenant_id = setup.tenant_id AND principal.id = setup.owner_principal_id
      JOIN attune.hosted_channel_preferences preference
        ON preference.tenant_id = setup.tenant_id
       AND preference.owner_principal_id = setup.owner_principal_id
     WHERE setup.provider = 'google_chat' AND setup.mechanism = 'link_code'
       AND setup.secret_hash = p_secret_hash AND setup.state = 'claimed'
       AND setup.claim_hash = p_claim_hash
       AND setup.claim_expires_at > clock_timestamp()
       AND setup.expires_at > clock_timestamp()
       AND tenant.status = 'active' AND principal.status = 'active'
       AND setup.preference_revision = preference.revision
       AND 'google_chat' = ANY(preference.interaction_channels || preference.brief_channels)
     FOR UPDATE OF setup;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'channel link is unavailable' USING ERRCODE = 'P0002';
    END IF;
    SELECT destination.* INTO v_existing
      FROM attune.hosted_channel_destinations destination
     WHERE destination.tenant_id = v_setup.tenant_id
       AND destination.provider = 'google_chat'
     FOR UPDATE;
    IF FOUND AND (
        v_existing.owner_principal_id <> v_setup.owner_principal_id
        OR v_existing.status NOT IN ('pending_test', 'revoked')
        OR (
            v_existing.status = 'pending_test' AND (
                v_existing.route_version IS NOT NULL
                OR v_existing.installation_ref_hash <> p_installation_ref_hash
                OR v_existing.actor_ref_hash <> p_actor_ref_hash
                OR v_existing.destination_ref_hash <> p_destination_ref_hash
            )
        )
    ) THEN
        RAISE EXCEPTION 'channel destination requires replacement ceremony'
            USING ERRCODE = '23514';
    END IF;

    IF NOT FOUND THEN
      INSERT INTO attune.installations (
        tenant_id, provider, kind, external_ref_hash, metadata
      ) VALUES (
        v_setup.tenant_id, 'google', 'channel', p_installation_ref_hash,
        jsonb_build_object('surface', 'google_chat', 'schema_version', 1)
      ) RETURNING id INTO v_installation_id;
      INSERT INTO attune.hosted_channel_destinations (
        tenant_id, id, owner_principal_id, installation_id, provider,
        installation_ref_hash, actor_ref_hash, destination_ref_hash,
        ingress_verified_at, route_version
      ) VALUES (
        v_setup.tenant_id, p_destination_id, v_setup.owner_principal_id,
        v_installation_id, 'google_chat', p_installation_ref_hash,
        p_actor_ref_hash, p_destination_ref_hash, clock_timestamp(), 1
      );
    ELSIF v_existing.status = 'pending_test' THEN
      v_installation_id := v_existing.installation_id;
      p_destination_id := v_existing.id;
      UPDATE attune.hosted_channel_destinations destination
         SET route_version = 1, updated_at = clock_timestamp()
       WHERE destination.tenant_id = v_setup.tenant_id
         AND destination.id = v_existing.id;
    ELSE
      SELECT installation.id INTO v_installation_id
        FROM attune.installations installation
       WHERE installation.tenant_id = v_setup.tenant_id
         AND installation.provider = 'google'
         AND installation.kind = 'channel'
         AND installation.external_ref_hash = p_installation_ref_hash
       FOR UPDATE;
      IF NOT FOUND THEN
        INSERT INTO attune.installations (
          tenant_id, provider, kind, external_ref_hash, metadata
        ) VALUES (
          v_setup.tenant_id, 'google', 'channel', p_installation_ref_hash,
          jsonb_build_object('surface', 'google_chat', 'schema_version', 1)
        ) RETURNING id INTO v_installation_id;
      ELSE
        UPDATE attune.installations installation
           SET status = 'active', updated_at = clock_timestamp()
         WHERE installation.tenant_id = v_setup.tenant_id
           AND installation.id = v_installation_id;
      END IF;
      UPDATE attune.installations installation
         SET status = 'revoked', updated_at = clock_timestamp()
       WHERE installation.tenant_id = v_setup.tenant_id
         AND installation.id = v_existing.installation_id
         AND installation.id <> v_installation_id;
      DELETE FROM attune.hosted_channel_routes route
       WHERE route.tenant_id = v_setup.tenant_id
         AND route.destination_id = v_existing.id;
      p_destination_id := v_existing.id;
      UPDATE attune.hosted_channel_destinations destination
         SET installation_id = v_installation_id,
             installation_ref_hash = p_installation_ref_hash,
             actor_ref_hash = p_actor_ref_hash,
             destination_ref_hash = p_destination_ref_hash,
             status = 'pending_test', ingress_verified_at = clock_timestamp(),
             delivery_verified_at = NULL, route_version = 1,
             delivery_claim_hash = NULL, delivery_claim_expires_at = NULL,
             version = destination.version + 1,
             updated_at = clock_timestamp()
       WHERE destination.tenant_id = v_setup.tenant_id
         AND destination.id = v_existing.id;
    END IF;
    INSERT INTO attune.hosted_channel_routes (
        tenant_id, destination_id, ciphertext, nonce, wrapped_dek,
        key_resource, format_version
    ) VALUES (
        v_setup.tenant_id, p_destination_id, p_ciphertext, p_nonce,
        p_wrapped_dek, p_key_resource, p_format_version
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
        'provider', p_actor_ref_hash, 'hosted.channels.google_chat.link',
        'observed', 'owner_dm', p_destination_ref_hash,
        jsonb_build_object('schema_version', 1)
    ) RETURNING id INTO v_audit_id;
    RETURN QUERY SELECT v_setup.tenant_id, v_setup.owner_principal_id,
                        v_installation_id, p_destination_id,
                        'pending_test'::text, v_audit_id;
END
$function$;

REVOKE ALL ON FUNCTION attune.consume_google_chat_link_v2(
    bytea,bytea,bytea,bytea,bytea,uuid,bytea,bytea,bytea,text,integer
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION attune.consume_google_chat_link_v2(
    bytea,bytea,bytea,bytea,bytea,uuid,bytea,bytea,bytea,text,integer
) TO attune_channel_broker;
GRANT UPDATE ON attune.installations TO attune_channel_link_executor;
GRANT DELETE ON attune.hosted_channel_routes TO attune_channel_link_executor;

DO $grant_link_owner$
BEGIN
    EXECUTE pg_catalog.format('GRANT attune_channel_link_executor TO %I', current_user);
END
$grant_link_owner$;
GRANT CREATE ON SCHEMA attune TO attune_channel_link_executor;
ALTER FUNCTION attune.consume_google_chat_link_v2(
    bytea,bytea,bytea,bytea,bytea,uuid,bytea,bytea,bytea,text,integer
) OWNER TO attune_channel_link_executor;
REVOKE CREATE ON SCHEMA attune FROM attune_channel_link_executor;
DO $revoke_link_owner$
BEGIN
    EXECUTE pg_catalog.format('REVOKE attune_channel_link_executor FROM %I', current_user);
END
$revoke_link_owner$;

ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON FUNCTIONS FROM PUBLIC;
