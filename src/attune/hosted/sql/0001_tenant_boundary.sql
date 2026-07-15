CREATE SCHEMA attune_ext;
CREATE SCHEMA attune;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA attune_ext FROM PUBLIC;
REVOKE ALL ON SCHEMA attune FROM PUBLIC;

CREATE EXTENSION pgcrypto WITH SCHEMA attune_ext;
CREATE EXTENSION vector WITH SCHEMA attune_ext;

DO $roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'attune_control_plane') THEN
        CREATE ROLE attune_control_plane NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'attune_worker') THEN
        CREATE ROLE attune_worker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'attune_secret_broker') THEN
        CREATE ROLE attune_secret_broker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'attune_audit_writer') THEN
        CREATE ROLE attune_audit_writer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
END
$roles$;

CREATE FUNCTION attune.current_tenant_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $function$
DECLARE
    tenant_setting text := current_setting('attune.tenant_id', true);
BEGIN
    IF tenant_setting IS NULL OR tenant_setting = '' THEN
        RAISE EXCEPTION 'verified tenant context is required' USING ERRCODE = '42501';
    END IF;
    RETURN tenant_setting::uuid;
END
$function$;
REVOKE ALL ON FUNCTION attune.current_tenant_id() FROM PUBLIC;

CREATE TABLE attune.tenants (
    id uuid PRIMARY KEY DEFAULT attune_ext.gen_random_uuid(),
    slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deleting', 'deleted')),
    region text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE attune.principals (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    subject_hash bytea NOT NULL CHECK (octet_length(subject_hash) = 32),
    issuer text NOT NULL CHECK (length(issuer) BETWEEN 1 AND 255),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled', 'deleted')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, issuer, subject_hash),
    FOREIGN KEY (tenant_id) REFERENCES attune.tenants(id)
);

CREATE TABLE attune.installations (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    provider text NOT NULL CHECK (provider IN ('google', 'slack')),
    kind text NOT NULL CHECK (kind IN ('workspace', 'channel')),
    external_ref_hash bytea NOT NULL CHECK (octet_length(external_ref_hash) = 32),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled', 'revoked')),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object' AND pg_column_size(metadata) <= 16384),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, provider, external_ref_hash),
    FOREIGN KEY (tenant_id) REFERENCES attune.tenants(id)
);

CREATE TABLE attune.connectors (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    principal_id uuid,
    installation_id uuid,
    provider text NOT NULL CHECK (provider IN ('google', 'slack', 'mcp', 'model')),
    credential_ref uuid NOT NULL,
    granted_scopes text[] NOT NULL DEFAULT ARRAY[]::text[],
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'revoked', 'error')),
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, credential_ref),
    FOREIGN KEY (tenant_id, principal_id) REFERENCES attune.principals(tenant_id, id),
    FOREIGN KEY (tenant_id, installation_id) REFERENCES attune.installations(tenant_id, id),
    CHECK (principal_id IS NOT NULL OR installation_id IS NOT NULL)
);

CREATE TABLE attune.policies (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    version bigint NOT NULL CHECK (version > 0),
    document jsonb NOT NULL CHECK (jsonb_typeof(document) = 'object' AND pg_column_size(document) <= 65536),
    active boolean NOT NULL DEFAULT false,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, version),
    FOREIGN KEY (tenant_id, created_by) REFERENCES attune.principals(tenant_id, id)
);
CREATE UNIQUE INDEX policies_one_active_per_tenant ON attune.policies (tenant_id) WHERE active;

CREATE TABLE attune.jobs (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    kind text NOT NULL CHECK (length(kind) BETWEEN 1 AND 80),
    state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'leased', 'succeeded', 'failed', 'reconcile', 'cancelled')),
    idempotency_key bytea NOT NULL CHECK (octet_length(idempotency_key) = 32),
    capability text NOT NULL CHECK (length(capability) BETWEEN 1 AND 120),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object' AND pg_column_size(payload) <= 262144),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    available_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    lease_expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, idempotency_key),
    FOREIGN KEY (tenant_id) REFERENCES attune.tenants(id)
);
CREATE INDEX jobs_dispatch ON attune.jobs (tenant_id, state, available_at);

CREATE TABLE attune.approvals (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    job_id uuid NOT NULL,
    approver_id uuid NOT NULL,
    connector_id uuid NOT NULL,
    opaque_ref_hash bytea NOT NULL CHECK (octet_length(opaque_ref_hash) = 32),
    action_hash bytea NOT NULL CHECK (octet_length(action_hash) = 32),
    capability text NOT NULL CHECK (length(capability) BETWEEN 1 AND 120),
    destination_hash bytea NOT NULL CHECK (octet_length(destination_hash) = 32),
    source_version text NOT NULL CHECK (length(source_version) BETWEEN 1 AND 255),
    policy_version bigint NOT NULL CHECK (policy_version > 0),
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'expired', 'consumed')),
    expires_at timestamptz NOT NULL,
    decided_at timestamptz,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, opaque_ref_hash),
    FOREIGN KEY (tenant_id, job_id) REFERENCES attune.jobs(tenant_id, id),
    FOREIGN KEY (tenant_id, approver_id) REFERENCES attune.principals(tenant_id, id),
    FOREIGN KEY (tenant_id, connector_id) REFERENCES attune.connectors(tenant_id, id),
    CHECK (expires_at > created_at),
    CHECK ((status = 'pending') = (decided_at IS NULL)),
    CHECK ((status = 'consumed' AND consumed_at IS NOT NULL) OR status <> 'consumed')
);
CREATE INDEX approvals_pending ON attune.approvals (tenant_id, expires_at) WHERE status = 'pending';

CREATE TABLE attune.memories (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    principal_id uuid NOT NULL,
    creator_id uuid,
    content text NOT NULL CHECK (length(content) BETWEEN 1 AND 65536),
    provenance jsonb NOT NULL CHECK (jsonb_typeof(provenance) = 'object' AND pg_column_size(provenance) <= 32768),
    source_class text NOT NULL CHECK (source_class IN ('user_taught', 'provider', 'assistant_derived', 'system')),
    confidence real NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at timestamptz,
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id, principal_id) REFERENCES attune.principals(tenant_id, id),
    FOREIGN KEY (tenant_id, creator_id) REFERENCES attune.principals(tenant_id, id)
);

CREATE TABLE attune.memory_embeddings (
    tenant_id uuid NOT NULL,
    memory_id uuid NOT NULL,
    model text NOT NULL CHECK (length(model) BETWEEN 1 AND 255),
    dimensions integer NOT NULL CHECK (dimensions BETWEEN 1 AND 4096),
    embedding attune_ext.vector NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at timestamptz,
    PRIMARY KEY (tenant_id, memory_id, model),
    FOREIGN KEY (tenant_id, memory_id) REFERENCES attune.memories(tenant_id, id),
    CHECK (attune_ext.vector_dims(embedding) = dimensions)
);

CREATE TABLE attune.audit_heads (
    tenant_id uuid PRIMARY KEY,
    sequence bigint NOT NULL DEFAULT 0 CHECK (sequence >= 0),
    event_hash bytea NOT NULL DEFAULT decode(repeat('00', 32), 'hex') CHECK (octet_length(event_hash) = 32),
    FOREIGN KEY (tenant_id) REFERENCES attune.tenants(id)
);

CREATE TABLE attune.audit_events (
    tenant_id uuid NOT NULL,
    sequence bigint NOT NULL CHECK (sequence > 0),
    id uuid NOT NULL,
    occurred_at timestamptz NOT NULL,
    actor_type text NOT NULL CHECK (length(actor_type) BETWEEN 1 AND 64),
    actor_ref_hash bytea CHECK (actor_ref_hash IS NULL OR octet_length(actor_ref_hash) = 32),
    action text NOT NULL CHECK (length(action) BETWEEN 1 AND 120),
    outcome text NOT NULL CHECK (outcome IN ('allowed', 'denied', 'failed', 'observed')),
    target_type text CHECK (target_type IS NULL OR length(target_type) BETWEEN 1 AND 64),
    target_ref_hash bytea CHECK (target_ref_hash IS NULL OR octet_length(target_ref_hash) = 32),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object' AND pg_column_size(metadata) <= 16384),
    previous_hash bytea NOT NULL CHECK (octet_length(previous_hash) = 32),
    event_hash bytea NOT NULL CHECK (octet_length(event_hash) = 32),
    PRIMARY KEY (tenant_id, sequence),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id) REFERENCES attune.tenants(id)
);

CREATE FUNCTION attune.reject_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
    RAISE EXCEPTION 'audit records are append-only' USING ERRCODE = '42501';
END
$function$;

CREATE TRIGGER audit_events_no_update_delete
BEFORE UPDATE OR DELETE ON attune.audit_events
FOR EACH ROW EXECUTE FUNCTION attune.reject_audit_mutation();
CREATE TRIGGER audit_events_no_truncate
BEFORE TRUNCATE ON attune.audit_events
FOR EACH STATEMENT EXECUTE FUNCTION attune.reject_audit_mutation();

CREATE FUNCTION attune.append_audit_event(
    p_tenant_id uuid,
    p_actor_type text,
    p_actor_ref_hash bytea,
    p_action text,
    p_outcome text,
    p_target_type text,
    p_target_ref_hash bytea,
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_id uuid := attune_ext.gen_random_uuid();
    v_occurred_at timestamptz := clock_timestamp();
    v_previous_hash bytea;
    v_event_hash bytea;
    v_sequence bigint;
BEGIN
    IF p_tenant_id IS NULL OR p_tenant_id IS DISTINCT FROM attune.current_tenant_id() THEN
        RAISE EXCEPTION 'verified tenant context is required' USING ERRCODE = '42501';
    END IF;
    IF p_actor_type IS NULL OR length(p_actor_type) NOT BETWEEN 1 AND 64
       OR p_action IS NULL OR length(p_action) NOT BETWEEN 1 AND 120
       OR p_outcome NOT IN ('allowed', 'denied', 'failed', 'observed')
       OR jsonb_typeof(p_metadata) <> 'object' OR pg_column_size(p_metadata) > 16384
       OR (p_actor_ref_hash IS NOT NULL AND octet_length(p_actor_ref_hash) <> 32)
       OR (p_target_ref_hash IS NOT NULL AND octet_length(p_target_ref_hash) <> 32) THEN
        RAISE EXCEPTION 'invalid audit event' USING ERRCODE = '22023';
    END IF;

    INSERT INTO attune.audit_heads (tenant_id) VALUES (p_tenant_id)
    ON CONFLICT (tenant_id) DO NOTHING;
    SELECT sequence, event_hash INTO v_sequence, v_previous_hash
      FROM attune.audit_heads WHERE tenant_id = p_tenant_id FOR UPDATE;
    v_sequence := v_sequence + 1;
    v_event_hash := attune_ext.digest(
        v_previous_hash || convert_to(
            concat_ws(E'\\x1f', p_tenant_id::text, v_sequence::text, v_id::text,
                v_occurred_at::text, p_actor_type,
                COALESCE(encode(p_actor_ref_hash, 'hex'), ''), p_action,
                p_outcome, COALESCE(p_target_type, ''),
                COALESCE(encode(p_target_ref_hash, 'hex'), ''),
                p_metadata::text),
            'UTF8'),
        'sha256');

    INSERT INTO attune.audit_events (
        tenant_id, sequence, id, occurred_at, actor_type, actor_ref_hash,
        action, outcome, target_type, target_ref_hash, metadata,
        previous_hash, event_hash
    ) VALUES (
        p_tenant_id, v_sequence, v_id, v_occurred_at, p_actor_type,
        p_actor_ref_hash, p_action, p_outcome, p_target_type,
        p_target_ref_hash, p_metadata, v_previous_hash, v_event_hash
    );
    UPDATE attune.audit_heads
       SET sequence = v_sequence, event_hash = v_event_hash
     WHERE tenant_id = p_tenant_id;
    RETURN v_id;
END
$function$;

REVOKE ALL ON ALL TABLES IN SCHEMA attune FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA attune FROM PUBLIC;

DO $rls$
DECLARE
    table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'principals', 'installations', 'connectors', 'policies', 'jobs',
        'approvals', 'memories', 'memory_embeddings', 'audit_heads', 'audit_events'
    ]
    LOOP
        EXECUTE format('ALTER TABLE attune.%I ENABLE ROW LEVEL SECURITY', table_name);
        EXECUTE format('ALTER TABLE attune.%I FORCE ROW LEVEL SECURITY', table_name);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON attune.%I USING (' ||
            'tenant_id = attune.current_tenant_id()) WITH CHECK (' ||
            'tenant_id = attune.current_tenant_id())',
            table_name);
    END LOOP;
END
$rls$;

ALTER TABLE attune.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE attune.tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON attune.tenants
USING (id = attune.current_tenant_id())
WITH CHECK (id = attune.current_tenant_id());

GRANT USAGE ON SCHEMA attune TO attune_control_plane, attune_worker, attune_secret_broker, attune_audit_writer;
GRANT USAGE ON SCHEMA attune_ext TO attune_control_plane, attune_worker;
GRANT EXECUTE ON FUNCTION attune.current_tenant_id() TO attune_control_plane, attune_worker, attune_secret_broker, attune_audit_writer;

GRANT SELECT, INSERT, UPDATE ON
    attune.tenants, attune.principals, attune.installations, attune.connectors,
    attune.policies, attune.jobs, attune.approvals, attune.memories,
    attune.memory_embeddings
TO attune_control_plane;
GRANT SELECT ON attune.audit_events TO attune_control_plane;

GRANT SELECT ON attune.connectors, attune.policies TO attune_worker;
GRANT SELECT, INSERT, UPDATE ON attune.jobs, attune.approvals, attune.memories,
    attune.memory_embeddings TO attune_worker;

GRANT SELECT, UPDATE ON attune.connectors TO attune_secret_broker;
GRANT EXECUTE ON FUNCTION attune.append_audit_event(uuid, text, bytea, text, text, text, bytea, jsonb)
TO attune_audit_writer;

ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON FUNCTIONS FROM PUBLIC;
