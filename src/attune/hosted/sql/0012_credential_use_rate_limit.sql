-- The function is owned by a memberless BYPASSRLS executor. Temporarily grant
-- the migrator membership so CREATE OR REPLACE can preserve that owner; a
-- failure rolls back both the function change and membership grant.
DO $grant_vault_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'GRANT attune_vault_executor TO %I', current_user
    );
END
$grant_vault_owner$;

CREATE OR REPLACE FUNCTION attune.lease_credential_intent(
    p_intent_id uuid, p_producer_kind text, p_lease_seconds integer
)
RETURNS TABLE (
    intent_id uuid, tenant_id uuid, connector_id uuid, provider text,
    operation text, capability text, credential_id uuid,
    credential_version integer, format_version integer, ciphertext bytea,
    nonce bytea, wrapped_dek bytea, key_resource text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_tenant_id uuid;
    v_operation text;
    v_capability text;
    v_recent_uses bigint;
BEGIN
    IF p_producer_kind NOT IN ('control_plane', 'worker')
       OR p_lease_seconds NOT BETWEEN 1 AND 300 THEN
        RAISE EXCEPTION 'invalid credential lease request' USING ERRCODE = '22023';
    END IF;

    SELECT intent.tenant_id, intent.operation, intent.capability
      INTO v_tenant_id, v_operation, v_capability
      FROM attune.credential_intents AS intent
     WHERE intent.id = p_intent_id
       AND intent.producer_kind = p_producer_kind
       AND intent.expires_at > clock_timestamp()
       AND (intent.state = 'requested' OR
            (intent.state = 'leased'
             AND intent.lease_expires_at <= clock_timestamp()));

    IF v_operation = 'use' THEN
        -- Serialize one tenant/capability bucket across every broker instance.
        -- Hash collisions can only reduce availability; they cannot add quota.
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(
                'attune-credential-use-v1:' || v_tenant_id::text || ':' ||
                v_capability,
                731945207
            )
        );
        SELECT count(*)
          INTO v_recent_uses
          FROM attune.credential_intents AS recent
         WHERE recent.tenant_id = v_tenant_id
           AND recent.operation = 'use'
           AND recent.capability = v_capability
           AND recent.attempts > 0
           AND recent.state IN ('leased', 'consumed', 'failed')
           AND recent.updated_at > clock_timestamp() - interval '1 minute';
        IF v_recent_uses >= 60 THEN
            RETURN;
        END IF;
    END IF;

    RETURN QUERY
    WITH candidate AS (
        SELECT intent.id
          FROM attune.credential_intents AS intent
         WHERE intent.id = p_intent_id
           AND intent.producer_kind = p_producer_kind
           AND intent.expires_at > clock_timestamp()
           AND (intent.state = 'requested' OR
                (intent.state = 'leased' AND
                 intent.lease_expires_at <= clock_timestamp()))
           AND (
               intent.operation = 'use'
               OR NOT EXISTS (
                   SELECT 1 FROM attune.credential_intents AS other
                    WHERE other.tenant_id = intent.tenant_id
                      AND other.connector_id = intent.connector_id
                      AND other.id <> intent.id
                      AND other.operation IN ('install', 'revoke')
                      AND other.state = 'leased'
                      AND other.lease_expires_at > clock_timestamp()
               )
           )
         FOR UPDATE
    ), leased AS (
        UPDATE attune.credential_intents AS intent
           SET state = 'leased', attempts = intent.attempts + 1,
               lease_expires_at = clock_timestamp() +
                                  p_lease_seconds * interval '1 second',
               updated_at = clock_timestamp()
          FROM candidate
         WHERE intent.id = candidate.id
        RETURNING intent.*
    )
    SELECT leased.id, leased.tenant_id, leased.connector_id, connector.provider,
           leased.operation, leased.capability, credential.id,
           credential.credential_version, credential.format_version,
           credential.ciphertext, credential.nonce, credential.wrapped_dek,
           credential.key_resource
      FROM leased
      JOIN attune.connectors AS connector
        ON connector.tenant_id = leased.tenant_id
       AND connector.id = leased.connector_id
      LEFT JOIN attune.connector_credentials AS credential
        ON credential.tenant_id = leased.tenant_id
       AND credential.connector_id = leased.connector_id
       AND credential.status = 'active'
     WHERE leased.operation = 'install' OR credential.id IS NOT NULL;
END $function$;

REVOKE ALL ON FUNCTION attune.lease_credential_intent(uuid,text,integer)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION attune.lease_credential_intent(uuid,text,integer)
TO attune_secret_broker;

DO $revoke_vault_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'REVOKE attune_vault_executor FROM %I', current_user
    );
END
$revoke_vault_owner$;
