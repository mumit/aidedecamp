DO $roles$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'attune_identity_executor'
    ) THEN
        CREATE ROLE attune_identity_executor
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
    END IF;
END
$roles$;

CREATE TABLE attune.identity_sessions (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    principal_id uuid NOT NULL,
    token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
    csrf_hash bytea NOT NULL CHECK (octet_length(csrf_hash) = 32),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id, principal_id)
        REFERENCES attune.principals(tenant_id, id),
    CHECK (expires_at > created_at),
    CHECK (expires_at <= created_at + interval '12 hours'),
    CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE INDEX identity_sessions_expiry
ON attune.identity_sessions (expires_at)
WHERE revoked_at IS NULL;

ALTER TABLE attune.identity_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE attune.identity_sessions FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON attune.identity_sessions
USING (tenant_id = attune.current_tenant_id())
WITH CHECK (tenant_id = attune.current_tenant_id());

CREATE FUNCTION attune.open_identity_session(
    p_subject_hash bytea, p_issuer text, p_token_hash bytea,
    p_csrf_hash bytea, p_expires_at timestamptz
)
RETURNS TABLE (session_id uuid, tenant_id uuid, principal_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
BEGIN
    IF p_subject_hash IS NULL OR octet_length(p_subject_hash) <> 32
       OR p_token_hash IS NULL OR octet_length(p_token_hash) <> 32
       OR p_csrf_hash IS NULL OR octet_length(p_csrf_hash) <> 32
       OR p_issuer IS NULL OR length(p_issuer) NOT BETWEEN 1 AND 255
       OR p_issuer !~ '^https://securetoken[.]google[.]com/[a-z][a-z0-9-]{4,29}$'
       OR p_expires_at IS NULL
       OR p_expires_at < clock_timestamp() + interval '5 minutes'
       OR p_expires_at > clock_timestamp() + interval '12 hours' THEN
        RAISE EXCEPTION 'invalid identity session request'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH matches AS MATERIALIZED (
        SELECT principal.tenant_id, principal.id AS principal_id
          FROM attune.principals AS principal
          JOIN attune.tenants AS tenant ON tenant.id = principal.tenant_id
         WHERE principal.subject_hash = p_subject_hash
           AND principal.issuer = p_issuer
           AND principal.status = 'active'
           AND tenant.status = 'active'
         ORDER BY principal.tenant_id
         LIMIT 2
    ), unambiguous AS (
        SELECT matches.tenant_id, matches.principal_id
          FROM matches
         WHERE (SELECT count(*) FROM matches) = 1
    )
    INSERT INTO attune.identity_sessions
        (tenant_id, principal_id, token_hash, csrf_hash, expires_at)
    SELECT unambiguous.tenant_id, unambiguous.principal_id,
           p_token_hash, p_csrf_hash, p_expires_at
      FROM unambiguous
    RETURNING identity_sessions.id, identity_sessions.tenant_id,
              identity_sessions.principal_id;
END
$function$;

CREATE FUNCTION attune.read_identity_session(p_token_hash bytea)
RETURNS TABLE (session_id uuid, tenant_id uuid, principal_id uuid)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $function$
    SELECT session.id, session.tenant_id, session.principal_id
      FROM attune.identity_sessions AS session
      JOIN attune.principals AS principal
        ON principal.tenant_id = session.tenant_id
       AND principal.id = session.principal_id
      JOIN attune.tenants AS tenant ON tenant.id = session.tenant_id
     WHERE p_token_hash IS NOT NULL
       AND octet_length(p_token_hash) = 32
       AND session.token_hash = p_token_hash
       AND session.revoked_at IS NULL
       AND session.expires_at > clock_timestamp()
       AND principal.status = 'active'
       AND tenant.status = 'active'
$function$;

CREATE FUNCTION attune.authorize_identity_session(
    p_token_hash bytea, p_csrf_hash bytea
)
RETURNS TABLE (session_id uuid, tenant_id uuid, principal_id uuid)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $function$
    UPDATE attune.identity_sessions AS session
       SET last_seen_at = clock_timestamp()
      FROM attune.principals AS principal, attune.tenants AS tenant
     WHERE p_token_hash IS NOT NULL AND octet_length(p_token_hash) = 32
       AND p_csrf_hash IS NOT NULL AND octet_length(p_csrf_hash) = 32
       AND session.token_hash = p_token_hash
       AND session.csrf_hash = p_csrf_hash
       AND session.revoked_at IS NULL
       AND session.expires_at > clock_timestamp()
       AND principal.tenant_id = session.tenant_id
       AND principal.id = session.principal_id
       AND principal.status = 'active'
       AND tenant.id = session.tenant_id
       AND tenant.status = 'active'
    RETURNING session.id, session.tenant_id, session.principal_id
$function$;

CREATE FUNCTION attune.revoke_identity_session(
    p_token_hash bytea, p_csrf_hash bytea
)
RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $function$
    UPDATE attune.identity_sessions AS session
       SET revoked_at = clock_timestamp(), last_seen_at = clock_timestamp()
     WHERE p_token_hash IS NOT NULL AND octet_length(p_token_hash) = 32
       AND p_csrf_hash IS NOT NULL AND octet_length(p_csrf_hash) = 32
       AND session.token_hash = p_token_hash
       AND session.csrf_hash = p_csrf_hash
       AND session.revoked_at IS NULL
       AND session.expires_at > clock_timestamp()
    RETURNING true
$function$;

REVOKE ALL ON TABLE attune.identity_sessions FROM PUBLIC;
REVOKE ALL ON FUNCTION
    attune.open_identity_session(bytea,text,bytea,bytea,timestamptz),
    attune.read_identity_session(bytea),
    attune.authorize_identity_session(bytea,bytea),
    attune.revoke_identity_session(bytea,bytea)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.open_identity_session(bytea,text,bytea,bytea,timestamptz),
    attune.read_identity_session(bytea),
    attune.authorize_identity_session(bytea,bytea),
    attune.revoke_identity_session(bytea,bytea)
TO attune_control_plane;

DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format('GRANT attune_identity_executor TO %I', current_user);
END
$grant_owner$;
GRANT USAGE, CREATE ON SCHEMA attune TO attune_identity_executor;
GRANT SELECT ON attune.tenants, attune.principals TO attune_identity_executor;
GRANT SELECT, INSERT, UPDATE ON attune.identity_sessions
TO attune_identity_executor;
ALTER FUNCTION attune.open_identity_session(bytea,text,bytea,bytea,timestamptz)
OWNER TO attune_identity_executor;
ALTER FUNCTION attune.read_identity_session(bytea)
OWNER TO attune_identity_executor;
ALTER FUNCTION attune.authorize_identity_session(bytea,bytea)
OWNER TO attune_identity_executor;
ALTER FUNCTION attune.revoke_identity_session(bytea,bytea)
OWNER TO attune_identity_executor;
REVOKE CREATE ON SCHEMA attune FROM attune_identity_executor;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format('REVOKE attune_identity_executor FROM %I', current_user);
END
$revoke_owner$;

ALTER DEFAULT PRIVILEGES IN SCHEMA attune
REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA attune
REVOKE ALL ON FUNCTIONS FROM PUBLIC;
