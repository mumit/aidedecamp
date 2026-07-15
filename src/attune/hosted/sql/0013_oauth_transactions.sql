DO $roles$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'attune_oauth_exchange'
    ) THEN
        CREATE ROLE attune_oauth_exchange
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'attune_oauth_executor'
    ) THEN
        CREATE ROLE attune_oauth_executor
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
    END IF;
END
$roles$;

CREATE TABLE attune.oauth_transactions (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    principal_id uuid NOT NULL,
    connector_id uuid NOT NULL,
    provider text NOT NULL CHECK (provider = 'google'),
    state_hash bytea NOT NULL CHECK (octet_length(state_hash) = 32),
    binding_hash bytea NOT NULL CHECK (octet_length(binding_hash) = 32),
    nonce_hash bytea NOT NULL CHECK (octet_length(nonce_hash) = 32),
    pkce_verifier text NOT NULL
        CHECK (length(pkce_verifier) BETWEEN 43 AND 128
               AND pkce_verifier ~ '^[A-Za-z0-9_-]+$'),
    redirect_uri text NOT NULL
        CHECK (length(redirect_uri) BETWEEN 16 AND 2048
               AND redirect_uri ~ '^https://'),
    scopes text[] NOT NULL CHECK (
        array_ndims(scopes) = 1 AND
        cardinality(scopes) BETWEEN 1 AND 32 AND
        array_position(scopes, NULL) IS NULL
    ),
    state text NOT NULL DEFAULT 'pending'
        CHECK (state IN ('pending', 'leased', 'completed', 'failed', 'expired')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 10),
    expires_at timestamptz NOT NULL,
    lease_expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (id),
    UNIQUE (state_hash),
    FOREIGN KEY (tenant_id, principal_id)
        REFERENCES attune.principals(tenant_id, id),
    FOREIGN KEY (tenant_id, connector_id)
        REFERENCES attune.connectors(tenant_id, id),
    CHECK (expires_at > created_at AND expires_at <= created_at + interval '15 minutes'),
    CHECK ((state = 'leased') = (lease_expires_at IS NOT NULL))
);
CREATE INDEX oauth_transactions_expiry
    ON attune.oauth_transactions (expires_at)
    WHERE state IN ('pending', 'leased');

ALTER TABLE attune.oauth_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE attune.oauth_transactions FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON attune.oauth_transactions
USING (tenant_id = attune.current_tenant_id())
WITH CHECK (tenant_id = attune.current_tenant_id());

REVOKE ALL ON attune.oauth_transactions FROM PUBLIC;
GRANT SELECT, INSERT ON attune.oauth_transactions TO attune_control_plane;
GRANT USAGE ON SCHEMA attune TO attune_oauth_exchange;

CREATE FUNCTION attune.enforce_oauth_transaction_insert()
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
        SELECT 1 FROM attune.connectors AS connector
         WHERE connector.tenant_id = NEW.tenant_id
           AND connector.id = NEW.connector_id
           AND connector.principal_id = NEW.principal_id
           AND connector.provider = NEW.provider
           AND connector.status = 'pending'
    ) THEN
        RAISE EXCEPTION 'OAuth connector is not pending for the principal'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION attune.enforce_oauth_transaction_insert() FROM PUBLIC;
CREATE TRIGGER oauth_transaction_insert_guard
BEFORE INSERT ON attune.oauth_transactions
FOR EACH ROW EXECUTE FUNCTION attune.enforce_oauth_transaction_insert();

CREATE FUNCTION attune.lease_oauth_transaction(
    p_state_hash bytea, p_binding_hash bytea, p_lease_seconds integer
)
RETURNS TABLE (
    transaction_id uuid, tenant_id uuid, principal_id uuid, connector_id uuid,
    provider text, nonce_hash bytea, pkce_verifier text, redirect_uri text,
    scopes text[]
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
               SELECT 1 FROM attune.connectors AS connector
                WHERE connector.tenant_id = transaction.tenant_id
                  AND connector.id = transaction.connector_id
                  AND connector.principal_id = transaction.principal_id
                  AND connector.provider = transaction.provider
                  AND connector.status = 'pending'
           )
        RETURNING transaction.*
    )
    SELECT leased.id, leased.tenant_id, leased.principal_id,
           leased.connector_id, leased.provider, leased.nonce_hash,
           leased.pkce_verifier, leased.redirect_uri, leased.scopes
      FROM leased;
END
$function$;

CREATE FUNCTION attune.finalize_oauth_transaction(
    p_transaction_id uuid, p_binding_hash bytea, p_outcome text
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $function$
BEGIN
    IF p_transaction_id IS NULL
       OR p_binding_hash IS NULL OR octet_length(p_binding_hash) <> 32
       OR p_outcome IS NULL OR p_outcome NOT IN ('completed', 'failed') THEN
        RAISE EXCEPTION 'invalid OAuth transaction outcome'
            USING ERRCODE = '22023';
    END IF;
    UPDATE attune.oauth_transactions AS transaction
       SET state = p_outcome, lease_expires_at = NULL,
           pkce_verifier = repeat('x', 43), updated_at = clock_timestamp()
     WHERE transaction.id = p_transaction_id
       AND transaction.binding_hash = p_binding_hash
       AND transaction.state = 'leased';
    RETURN FOUND;
END
$function$;

REVOKE ALL ON FUNCTION attune.lease_oauth_transaction(bytea,bytea,integer)
FROM PUBLIC;
REVOKE ALL ON FUNCTION attune.finalize_oauth_transaction(uuid,bytea,text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.lease_oauth_transaction(bytea,bytea,integer),
    attune.finalize_oauth_transaction(uuid,bytea,text)
TO attune_oauth_exchange;

DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format('GRANT attune_oauth_executor TO %I', current_user);
END
$grant_owner$;
GRANT USAGE, CREATE ON SCHEMA attune TO attune_oauth_executor;
GRANT SELECT, UPDATE ON attune.oauth_transactions TO attune_oauth_executor;
GRANT SELECT ON attune.connectors TO attune_oauth_executor;
ALTER FUNCTION attune.lease_oauth_transaction(bytea,bytea,integer)
OWNER TO attune_oauth_executor;
ALTER FUNCTION attune.finalize_oauth_transaction(uuid,bytea,text)
OWNER TO attune_oauth_executor;
REVOKE CREATE ON SCHEMA attune FROM attune_oauth_executor;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format('REVOKE attune_oauth_executor FROM %I', current_user);
END
$revoke_owner$;
