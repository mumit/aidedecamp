CREATE TABLE attune.connector_credentials (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    connector_id uuid NOT NULL,
    credential_version integer NOT NULL CHECK (credential_version > 0),
    format_version integer NOT NULL DEFAULT 1 CHECK (format_version = 1),
    ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) BETWEEN 17 AND 131072),
    nonce bytea NOT NULL CHECK (octet_length(nonce) = 12),
    wrapped_dek bytea NOT NULL CHECK (octet_length(wrapped_dek) BETWEEN 1 AND 65536),
    key_resource text NOT NULL CHECK (length(key_resource) BETWEEN 1 AND 512),
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'superseded', 'revoked')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    revoked_at timestamptz,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (id),
    UNIQUE (tenant_id, connector_id, credential_version),
    FOREIGN KEY (tenant_id, connector_id) REFERENCES attune.connectors(tenant_id, id),
    CHECK ((status = 'revoked') = (revoked_at IS NOT NULL))
);
CREATE UNIQUE INDEX connector_credentials_one_active
    ON attune.connector_credentials (tenant_id, connector_id)
    WHERE status = 'active';

CREATE TABLE attune.credential_intents (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    connector_id uuid NOT NULL,
    producer_kind text NOT NULL CHECK (producer_kind IN ('control_plane', 'worker')),
    operation text NOT NULL CHECK (operation IN ('install', 'use', 'revoke')),
    capability text NOT NULL CHECK (length(capability) BETWEEN 1 AND 120),
    idempotency_key bytea NOT NULL CHECK (octet_length(idempotency_key) = 32),
    state text NOT NULL DEFAULT 'requested'
        CHECK (state IN ('requested', 'leased', 'consumed', 'failed')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    expires_at timestamptz NOT NULL,
    lease_expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (id),
    UNIQUE (tenant_id, idempotency_key),
    FOREIGN KEY (tenant_id, connector_id) REFERENCES attune.connectors(tenant_id, id),
    CHECK (expires_at > created_at),
    CHECK ((state = 'leased') = (lease_expires_at IS NOT NULL))
);

ALTER TABLE attune.connector_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE attune.connector_credentials FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON attune.connector_credentials
USING (tenant_id = attune.current_tenant_id())
WITH CHECK (tenant_id = attune.current_tenant_id());
ALTER TABLE attune.credential_intents ENABLE ROW LEVEL SECURITY;
ALTER TABLE attune.credential_intents FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON attune.credential_intents
USING (tenant_id = attune.current_tenant_id())
WITH CHECK (tenant_id = attune.current_tenant_id());

REVOKE ALL ON attune.connector_credentials, attune.credential_intents FROM PUBLIC;
GRANT SELECT, INSERT ON attune.credential_intents TO attune_control_plane, attune_worker;

CREATE FUNCTION attune.enforce_credential_intent_insert()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $function$
DECLARE expected text;
BEGIN
    IF pg_catalog.pg_has_role(current_user, 'attune_control_plane', 'MEMBER')
       AND NOT pg_catalog.pg_has_role(current_user, 'attune_worker', 'MEMBER') THEN
        expected := 'control_plane';
    ELSIF pg_catalog.pg_has_role(current_user, 'attune_worker', 'MEMBER')
       AND NOT pg_catalog.pg_has_role(current_user, 'attune_control_plane', 'MEMBER') THEN
        expected := 'worker';
    ELSE
        expected := NULL;
    END IF;
    IF expected IS NULL OR NEW.producer_kind <> expected THEN
        RAISE EXCEPTION 'credential producer identity does not match intent'
            USING ERRCODE = '42501';
    END IF;
    IF (expected = 'control_plane' AND NEW.operation NOT IN ('install', 'revoke'))
       OR (expected = 'worker' AND NEW.operation <> 'use') THEN
        RAISE EXCEPTION 'credential operation is not allowed for producer'
            USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM attune.connectors AS connector
         WHERE connector.tenant_id = NEW.tenant_id
           AND connector.id = NEW.connector_id
           AND connector.status <> 'revoked'
    ) THEN
        RAISE EXCEPTION 'credential intent connector is unavailable'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $function$;
CREATE TRIGGER credential_intent_insert_guard
BEFORE INSERT ON attune.credential_intents
FOR EACH ROW EXECUTE FUNCTION attune.enforce_credential_intent_insert();

CREATE FUNCTION attune.lease_credential_intent(
    p_intent_id uuid, p_producer_kind text, p_lease_seconds integer
)
RETURNS TABLE (
    intent_id uuid, tenant_id uuid, connector_id uuid, provider text,
    operation text, capability text, credential_id uuid,
    credential_version integer, format_version integer, ciphertext bytea,
    nonce bytea, wrapped_dek bytea, key_resource text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
BEGIN
    IF p_producer_kind NOT IN ('control_plane', 'worker')
       OR p_lease_seconds NOT BETWEEN 1 AND 300 THEN
        RAISE EXCEPTION 'invalid credential lease request' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY
    WITH leased AS (
        UPDATE attune.credential_intents AS intent
           SET state = 'leased', attempts = intent.attempts + 1,
               lease_expires_at = clock_timestamp() + p_lease_seconds * interval '1 second',
               updated_at = clock_timestamp()
         WHERE intent.id = p_intent_id
           AND intent.producer_kind = p_producer_kind
           AND intent.expires_at > clock_timestamp()
           AND (intent.state = 'requested' OR
                (intent.state = 'leased' AND intent.lease_expires_at <= clock_timestamp()))
        RETURNING intent.*
    )
    SELECT leased.id, leased.tenant_id, leased.connector_id, connector.provider,
           leased.operation, leased.capability, credential.id,
           credential.credential_version, credential.format_version,
           credential.ciphertext, credential.nonce, credential.wrapped_dek,
           credential.key_resource
      FROM leased
      JOIN attune.connectors AS connector
        ON connector.tenant_id = leased.tenant_id AND connector.id = leased.connector_id
      LEFT JOIN attune.connector_credentials AS credential
        ON credential.tenant_id = leased.tenant_id
       AND credential.connector_id = leased.connector_id
       AND credential.status = 'active'
     WHERE leased.operation = 'install' OR credential.id IS NOT NULL;
END $function$;

CREATE FUNCTION attune.finalize_credential_intent(
    p_intent_id uuid, p_producer_kind text, p_outcome text
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
BEGIN
    IF p_outcome NOT IN ('consumed', 'failed') THEN
        RAISE EXCEPTION 'invalid credential outcome' USING ERRCODE = '22023';
    END IF;
    UPDATE attune.credential_intents AS intent
       SET state = p_outcome, lease_expires_at = NULL, updated_at = clock_timestamp()
     WHERE intent.id = p_intent_id AND intent.producer_kind = p_producer_kind
       AND intent.state = 'leased';
    RETURN FOUND;
END $function$;

REVOKE ALL ON FUNCTION attune.enforce_credential_intent_insert() FROM PUBLIC;
REVOKE ALL ON FUNCTION attune.lease_credential_intent(uuid,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION attune.finalize_credential_intent(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION attune.lease_credential_intent(uuid,text,integer)
TO attune_secret_broker;
GRANT EXECUTE ON FUNCTION attune.finalize_credential_intent(uuid,text,text)
TO attune_secret_broker;
