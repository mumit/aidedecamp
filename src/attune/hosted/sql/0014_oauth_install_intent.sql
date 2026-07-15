ALTER TABLE attune.oauth_transactions
ADD COLUMN credential_intent_id uuid NOT NULL;

ALTER TABLE attune.oauth_transactions
ADD CONSTRAINT oauth_transactions_credential_intent_fk
FOREIGN KEY (tenant_id, credential_intent_id)
REFERENCES attune.credential_intents(tenant_id, id) NOT VALID;

ALTER TABLE attune.oauth_transactions
ADD CONSTRAINT oauth_transactions_credential_intent_unique
UNIQUE (tenant_id, credential_intent_id);

CREATE OR REPLACE FUNCTION attune.enforce_oauth_transaction_insert()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $function$
BEGIN
    IF NOT pg_catalog.pg_has_role(
        current_user, 'attune_control_plane', 'MEMBER'
    ) THEN
        RAISE EXCEPTION 'OAuth transaction producer is not the control plane'
            USING ERRCODE = '42501';
    END IF;
    IF NEW.state <> 'pending' OR NEW.attempts <> 0
       OR NEW.lease_expires_at IS NOT NULL THEN
        RAISE EXCEPTION 'OAuth transaction must start pending'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_catalog.unnest(NEW.scopes) AS scope
         WHERE length(scope) NOT BETWEEN 1 AND 255
    ) OR cardinality(NEW.scopes) <> cardinality(
        ARRAY(SELECT DISTINCT scope FROM pg_catalog.unnest(NEW.scopes) AS scope)
    ) THEN
        RAISE EXCEPTION 'OAuth scopes must be bounded and unique'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM attune.connectors AS connector
          JOIN attune.credential_intents AS intent
            ON intent.tenant_id = connector.tenant_id
           AND intent.connector_id = connector.id
         WHERE connector.tenant_id = NEW.tenant_id
           AND connector.id = NEW.connector_id
           AND connector.principal_id = NEW.principal_id
           AND connector.provider = NEW.provider
           AND connector.status = 'pending'
           AND intent.id = NEW.credential_intent_id
           AND intent.producer_kind = 'control_plane'
           AND intent.operation = 'install'
           AND intent.capability = 'google.oauth.install'
           AND intent.state = 'requested'
           AND intent.expires_at >= NEW.expires_at
    ) THEN
        RAISE EXCEPTION 'OAuth install intent is not canonical and pending'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format('GRANT attune_oauth_executor TO %I', current_user);
END
$grant_owner$;

GRANT CREATE ON SCHEMA attune TO attune_oauth_executor;
SET LOCAL ROLE attune_oauth_executor;
REVOKE ALL ON FUNCTION attune.lease_oauth_transaction(bytea,bytea,integer)
FROM attune_oauth_exchange;
DROP FUNCTION attune.lease_oauth_transaction(bytea,bytea,integer);
RESET ROLE;

CREATE FUNCTION attune.lease_oauth_transaction(
    p_state_hash bytea, p_binding_hash bytea, p_lease_seconds integer
)
RETURNS TABLE (
    transaction_id uuid, tenant_id uuid, principal_id uuid, connector_id uuid,
    credential_intent_id uuid, provider text, nonce_hash bytea,
    pkce_verifier text, redirect_uri text, scopes text[]
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
BEGIN
    IF p_state_hash IS NULL OR octet_length(p_state_hash) <> 32
       OR p_binding_hash IS NULL OR octet_length(p_binding_hash) <> 32
       OR p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 1 AND 60 THEN
        RAISE EXCEPTION 'invalid OAuth transaction lease request'
            USING ERRCODE = '22023';
    END IF;
    RETURN QUERY
    WITH leased AS (
        UPDATE attune.oauth_transactions AS transaction
           SET state = 'leased', attempts = transaction.attempts + 1,
               lease_expires_at = clock_timestamp()
                   + p_lease_seconds * interval '1 second',
               updated_at = clock_timestamp()
         WHERE transaction.state_hash = p_state_hash
           AND transaction.binding_hash = p_binding_hash
           AND transaction.expires_at > clock_timestamp()
           AND transaction.attempts < 10
           AND (
               transaction.state = 'pending' OR
               (transaction.state = 'leased'
                AND transaction.lease_expires_at <= clock_timestamp())
           )
           AND EXISTS (
               SELECT 1
                 FROM attune.connectors AS connector
                 JOIN attune.credential_intents AS intent
                   ON intent.tenant_id = connector.tenant_id
                  AND intent.connector_id = connector.id
                WHERE connector.tenant_id = transaction.tenant_id
                  AND connector.id = transaction.connector_id
                  AND connector.principal_id = transaction.principal_id
                  AND connector.provider = transaction.provider
                  AND connector.status = 'pending'
                  AND intent.id = transaction.credential_intent_id
                  AND intent.producer_kind = 'control_plane'
                  AND intent.operation = 'install'
                  AND intent.capability = 'google.oauth.install'
                  AND intent.state = 'requested'
                  AND intent.expires_at >= transaction.expires_at
           )
        RETURNING transaction.*
    )
    SELECT leased.id, leased.tenant_id, leased.principal_id,
           leased.connector_id, leased.credential_intent_id, leased.provider,
           leased.nonce_hash, leased.pkce_verifier, leased.redirect_uri,
           leased.scopes
      FROM leased;
END
$function$;

REVOKE ALL ON FUNCTION attune.lease_oauth_transaction(bytea,bytea,integer)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.lease_oauth_transaction(bytea,bytea,integer)
TO attune_oauth_exchange;
GRANT SELECT ON attune.credential_intents TO attune_oauth_executor;
ALTER FUNCTION attune.lease_oauth_transaction(bytea,bytea,integer)
OWNER TO attune_oauth_executor;
REVOKE CREATE ON SCHEMA attune FROM attune_oauth_executor;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format('REVOKE attune_oauth_executor FROM %I', current_user);
END
$revoke_owner$;
