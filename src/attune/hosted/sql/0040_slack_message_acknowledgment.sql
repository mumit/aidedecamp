-- Slack's Events API ignores the synchronous response body (unlike Google
-- Chat, which renders it inline), so the owner otherwise gets no feedback
-- until the multi-second conversation pipeline replies. The private broker
-- now sends a fixed, audited acknowledgment right after a Slack owner
-- message is durably accepted and dispatched.
--
-- Mirrors 0038's claim_slack_delivery_test / complete_slack_delivery_test
-- envelope-returning shape, but resolves the destination by the same
-- reference hashes and full authority join as accept_slack_owner_message
-- (there is no destination_id available yet at the ingress boundary). The
-- claim is idempotent per provider message: a retried Slack event must not
-- send the fixed sentence twice.
DO $grant_link_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'GRANT attune_channel_link_executor TO %I', current_user
    );
END
$grant_link_owner$;
GRANT CREATE ON SCHEMA attune TO attune_channel_link_executor;
GRANT USAGE ON SCHEMA attune_ext TO attune_channel_link_executor;

CREATE FUNCTION attune.claim_slack_acknowledgment(
    p_installation_ref_hash bytea,
    p_actor_ref_hash bytea,
    p_destination_ref_hash bytea,
    p_message_ref_hash bytea
)
RETURNS TABLE (
    tenant_id uuid,
    destination_id uuid,
    route_ciphertext bytea, route_nonce bytea, route_wrapped_dek bytea,
    route_key_resource text, route_format_version integer,
    token_ciphertext bytea, token_nonce bytea, token_wrapped_dek bytea,
    token_key_resource text, token_format_version integer,
    pre_audit_intent_id uuid,
    won boolean
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_matches integer := 0;
    v_tenant_id uuid;
    v_destination_id uuid;
    v_route attune.hosted_channel_routes%ROWTYPE;
    v_credential attune.hosted_channel_credentials%ROWTYPE;
    v_audit_key bytea;
    v_audit_id uuid;
    candidate record;
BEGIN
    IF p_installation_ref_hash IS NULL
       OR octet_length(p_installation_ref_hash) <> 32
       OR p_actor_ref_hash IS NULL OR octet_length(p_actor_ref_hash) <> 32
       OR p_destination_ref_hash IS NULL
       OR octet_length(p_destination_ref_hash) <> 32
       OR p_message_ref_hash IS NULL OR octet_length(p_message_ref_hash) <> 32
    THEN
        RAISE EXCEPTION 'Slack acknowledgment request is invalid'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        'slack-ack-v1:' || encode(p_message_ref_hash, 'hex'), 0
    ));

    FOR candidate IN
        SELECT destination.tenant_id, destination.id AS destination_id
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
        v_destination_id := candidate.destination_id;
    END LOOP;
    IF v_matches <> 1 THEN
        RAISE EXCEPTION 'Slack owner destination is unavailable'
            USING ERRCODE = 'P0002';
    END IF;

    v_audit_key := attune_ext.digest(
        pg_catalog.convert_to(
            'slack-acknowledgment-audit-v1:' || encode(p_message_ref_hash, 'hex'),
            'UTF8'
        ), 'sha256'
    );
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, action, outcome,
        target_type, target_ref_hash, metadata
    ) VALUES (
        v_tenant_id, 'channel_broker', v_audit_key, 'assistant',
        'hosted.channels.slack.message.acknowledge', 'allowed',
        'provider_message', p_message_ref_hash,
        jsonb_build_object('schema_version', 1, 'content_profile', 'fixed_acknowledgment_v1')
    ) ON CONFLICT ON CONSTRAINT audit_intents_tenant_id_idempotency_key_key
      DO NOTHING
      RETURNING id INTO v_audit_id;

    IF v_audit_id IS NULL THEN
        -- Already acknowledged (Slack retried the event): report that this
        -- call did not win the claim without touching the route or token.
        RETURN QUERY SELECT v_tenant_id, v_destination_id,
            NULL::bytea, NULL::bytea, NULL::bytea, NULL::text, NULL::integer,
            NULL::bytea, NULL::bytea, NULL::bytea, NULL::text, NULL::integer,
            NULL::uuid, false;
        RETURN;
    END IF;

    SELECT route.* INTO STRICT v_route
      FROM attune.hosted_channel_routes route
     WHERE route.tenant_id = v_tenant_id
       AND route.destination_id = v_destination_id;
    SELECT credential.* INTO STRICT v_credential
      FROM attune.hosted_channel_credentials credential
     WHERE credential.tenant_id = v_tenant_id
       AND credential.destination_id = v_destination_id
       AND credential.purpose = 'slack_bot_token';

    RETURN QUERY SELECT v_tenant_id, v_destination_id,
        v_route.ciphertext, v_route.nonce, v_route.wrapped_dek,
        v_route.key_resource, v_route.format_version,
        v_credential.ciphertext, v_credential.nonce, v_credential.wrapped_dek,
        v_credential.key_resource, v_credential.format_version,
        v_audit_id, true;
END
$function$;

CREATE FUNCTION attune.complete_slack_acknowledgment(
    p_message_ref_hash bytea, p_succeeded boolean
)
RETURNS TABLE (outcome_audit_intent_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_pre_key bytea;
    v_pre attune.audit_intents%ROWTYPE;
    v_audit_key bytea;
    v_audit_id uuid;
BEGIN
    IF p_message_ref_hash IS NULL OR octet_length(p_message_ref_hash) <> 32
       OR p_succeeded IS NULL THEN
        RAISE EXCEPTION 'invalid Slack acknowledgment completion'
            USING ERRCODE = '22023';
    END IF;
    v_pre_key := attune_ext.digest(
        pg_catalog.convert_to(
            'slack-acknowledgment-audit-v1:' || encode(p_message_ref_hash, 'hex'),
            'UTF8'
        ), 'sha256'
    );
    SELECT intent.* INTO v_pre
      FROM attune.audit_intents intent
     WHERE intent.idempotency_key = v_pre_key
       AND intent.action = 'hosted.channels.slack.message.acknowledge'
       AND intent.outcome = 'allowed';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Slack acknowledgment claim is unavailable'
            USING ERRCODE = 'P0002';
    END IF;
    v_audit_key := set_byte(
        v_pre_key, 0,
        get_byte(v_pre_key, 0) # CASE WHEN p_succeeded THEN 1 ELSE 2 END
    );
    INSERT INTO attune.audit_intents (
        tenant_id, producer_kind, idempotency_key, actor_type, action, outcome,
        target_type, target_ref_hash, metadata
    ) VALUES (
        v_pre.tenant_id, 'channel_broker', v_audit_key, 'assistant',
        'hosted.channels.slack.message.acknowledge',
        CASE WHEN p_succeeded THEN 'observed' ELSE 'failed' END,
        'provider_message', p_message_ref_hash,
        jsonb_build_object('schema_version', 1, 'content_profile', 'fixed_acknowledgment_v1')
    ) ON CONFLICT ON CONSTRAINT audit_intents_tenant_id_idempotency_key_key
      DO NOTHING
      RETURNING id INTO v_audit_id;
    IF v_audit_id IS NULL THEN
        SELECT intent.id INTO STRICT v_audit_id FROM attune.audit_intents intent
         WHERE intent.tenant_id = v_pre.tenant_id
           AND intent.idempotency_key = v_audit_key;
    END IF;
    RETURN QUERY SELECT v_audit_id;
END
$function$;

REVOKE ALL ON FUNCTION
    attune.claim_slack_acknowledgment(bytea,bytea,bytea,bytea),
    attune.complete_slack_acknowledgment(bytea,boolean)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.claim_slack_acknowledgment(bytea,bytea,bytea,bytea),
    attune.complete_slack_acknowledgment(bytea,boolean)
TO attune_channel_broker;

ALTER FUNCTION attune.claim_slack_acknowledgment(bytea,bytea,bytea,bytea)
OWNER TO attune_channel_link_executor;
ALTER FUNCTION attune.complete_slack_acknowledgment(bytea,boolean)
OWNER TO attune_channel_link_executor;

REVOKE CREATE ON SCHEMA attune FROM attune_channel_link_executor;
DO $revoke_link_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'REVOKE attune_channel_link_executor FROM %I', current_user
    );
END
$revoke_link_owner$;

ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON FUNCTIONS FROM PUBLIC;
