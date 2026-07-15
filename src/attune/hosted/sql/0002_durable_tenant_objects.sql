CREATE TABLE attune.provider_events (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    installation_id uuid NOT NULL,
    provider text NOT NULL CHECK (provider IN ('google', 'slack')),
    kind text NOT NULL CHECK (length(kind) BETWEEN 1 AND 80),
    deduplication_key bytea NOT NULL CHECK (octet_length(deduplication_key) = 32),
    signal jsonb NOT NULL CHECK (jsonb_typeof(signal) = 'object' AND pg_column_size(signal) <= 32768),
    received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    processed_at timestamptz,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, provider, deduplication_key),
    FOREIGN KEY (tenant_id, installation_id) REFERENCES attune.installations(tenant_id, id)
);

CREATE TABLE attune.job_retries (
    tenant_id uuid NOT NULL,
    job_id uuid NOT NULL,
    attempt integer NOT NULL CHECK (attempt > 0),
    error_code text NOT NULL CHECK (length(error_code) BETWEEN 1 AND 80),
    available_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, job_id, attempt),
    FOREIGN KEY (tenant_id, job_id) REFERENCES attune.jobs(tenant_id, id)
);

CREATE TABLE attune.workflow_checkpoints (
    tenant_id uuid NOT NULL,
    workflow_id uuid NOT NULL,
    version bigint NOT NULL CHECK (version > 0),
    state jsonb NOT NULL CHECK (jsonb_typeof(state) = 'object' AND pg_column_size(state) <= 1048576),
    status text NOT NULL CHECK (status IN ('running', 'waiting', 'completed', 'failed', 'cancelled')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, workflow_id, version),
    FOREIGN KEY (tenant_id) REFERENCES attune.tenants(id)
);

CREATE TABLE attune.conversations (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    installation_id uuid NOT NULL,
    principal_id uuid NOT NULL,
    surface text NOT NULL CHECK (surface IN ('slack', 'google_chat', 'web')),
    external_ref_hash bytea NOT NULL CHECK (octet_length(external_ref_hash) = 32),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, surface, external_ref_hash),
    FOREIGN KEY (tenant_id, installation_id) REFERENCES attune.installations(tenant_id, id),
    FOREIGN KEY (tenant_id, principal_id) REFERENCES attune.principals(tenant_id, id)
);

CREATE TABLE attune.conversation_turns (
    tenant_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    sequence bigint NOT NULL CHECK (sequence > 0),
    actor_type text NOT NULL CHECK (actor_type IN ('user', 'assistant', 'system')),
    content text NOT NULL CHECK (length(content) BETWEEN 1 AND 131072),
    provenance jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(provenance) = 'object' AND pg_column_size(provenance) <= 32768),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, conversation_id, sequence),
    FOREIGN KEY (tenant_id, conversation_id) REFERENCES attune.conversations(tenant_id, id)
);

CREATE TABLE attune.autonomy_grants (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    principal_id uuid NOT NULL,
    capability text NOT NULL CHECK (length(capability) BETWEEN 1 AND 120),
    domain text NOT NULL CHECK (length(domain) BETWEEN 1 AND 80),
    maximum_risk smallint NOT NULL CHECK (maximum_risk BETWEEN 0 AND 4),
    policy_version bigint NOT NULL CHECK (policy_version > 0),
    granted_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    revoked_at timestamptz,
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id, principal_id) REFERENCES attune.principals(tenant_id, id),
    FOREIGN KEY (tenant_id, granted_by) REFERENCES attune.principals(tenant_id, id)
);
CREATE UNIQUE INDEX autonomy_one_active_grant
    ON attune.autonomy_grants (tenant_id, principal_id, capability, domain)
    WHERE revoked_at IS NULL;

CREATE TABLE attune.usage_records (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    category text NOT NULL CHECK (length(category) BETWEEN 1 AND 80),
    provider text NOT NULL CHECK (length(provider) BETWEEN 1 AND 80),
    units numeric(20, 6) NOT NULL CHECK (units >= 0),
    attributes jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(attributes) = 'object' AND pg_column_size(attributes) <= 8192),
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id) REFERENCES attune.tenants(id)
);

CREATE TABLE attune.export_jobs (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    requested_by uuid NOT NULL,
    scope jsonb NOT NULL CHECK (jsonb_typeof(scope) = 'object' AND pg_column_size(scope) <= 16384),
    state text NOT NULL DEFAULT 'requested' CHECK (state IN ('requested', 'running', 'ready', 'expired', 'failed', 'cancelled')),
    object_ref uuid,
    expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id, requested_by) REFERENCES attune.principals(tenant_id, id),
    CHECK ((state = 'ready' AND object_ref IS NOT NULL AND expires_at IS NOT NULL) OR state <> 'ready')
);

CREATE TABLE attune.deletion_markers (
    tenant_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT attune_ext.gen_random_uuid(),
    requested_by uuid NOT NULL,
    object_type text NOT NULL CHECK (length(object_type) BETWEEN 1 AND 80),
    object_ref_hash bytea NOT NULL CHECK (octet_length(object_ref_hash) = 32),
    state text NOT NULL DEFAULT 'requested' CHECK (state IN ('requested', 'running', 'completed', 'failed')),
    suppress_restore_until timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, object_type, object_ref_hash),
    FOREIGN KEY (tenant_id, requested_by) REFERENCES attune.principals(tenant_id, id),
    CHECK ((state = 'completed' AND completed_at IS NOT NULL) OR state <> 'completed')
);

DO $rls$
DECLARE
    table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'provider_events', 'job_retries', 'workflow_checkpoints',
        'conversations', 'conversation_turns', 'autonomy_grants',
        'usage_records', 'export_jobs', 'deletion_markers'
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

REVOKE ALL ON
    attune.provider_events, attune.job_retries, attune.workflow_checkpoints,
    attune.conversations, attune.conversation_turns, attune.autonomy_grants,
    attune.usage_records, attune.export_jobs, attune.deletion_markers
FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE ON
    attune.conversations, attune.conversation_turns, attune.autonomy_grants,
    attune.export_jobs, attune.deletion_markers
TO attune_control_plane;
GRANT SELECT ON attune.usage_records TO attune_control_plane;

GRANT SELECT, INSERT, UPDATE ON
    attune.provider_events, attune.job_retries, attune.workflow_checkpoints,
    attune.conversations, attune.conversation_turns, attune.usage_records,
    attune.export_jobs, attune.deletion_markers
TO attune_worker;
GRANT SELECT ON attune.autonomy_grants TO attune_worker;
