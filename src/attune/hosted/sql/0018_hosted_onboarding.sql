CREATE TABLE attune.hosted_onboarding_states (
    tenant_id uuid PRIMARY KEY,
    owner_principal_id uuid NOT NULL,
    schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version = 1),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    workspace_status text NOT NULL DEFAULT 'not_started'
        CHECK (workspace_status IN (
            'not_started', 'authorized', 'applied', 'validated', 'failed',
            'rolled_back', 'externally_modified'
        )),
    channels_status text NOT NULL DEFAULT 'not_started'
        CHECK (channels_status IN (
            'not_started', 'authorized', 'applied', 'validated', 'failed',
            'rolled_back', 'externally_modified'
        )),
    policy_status text NOT NULL DEFAULT 'not_started'
        CHECK (policy_status IN (
            'not_started', 'authorized', 'applied', 'validated', 'failed',
            'rolled_back', 'externally_modified'
        )),
    activation_status text NOT NULL DEFAULT 'not_started'
        CHECK (activation_status IN (
            'not_started', 'authorized', 'applied', 'validated', 'failed',
            'rolled_back', 'externally_modified'
        )),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (tenant_id) REFERENCES attune.tenants(id),
    FOREIGN KEY (tenant_id, owner_principal_id)
        REFERENCES attune.principals(tenant_id, id)
);

ALTER TABLE attune.hosted_onboarding_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE attune.hosted_onboarding_states FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON attune.hosted_onboarding_states
USING (tenant_id = attune.current_tenant_id())
WITH CHECK (tenant_id = attune.current_tenant_id());

CREATE FUNCTION attune.enforce_hosted_onboarding_insert()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $function$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM attune.principals AS principal
         WHERE principal.tenant_id = NEW.tenant_id
           AND principal.id = NEW.owner_principal_id
           AND principal.status = 'active'
    ) THEN
        RAISE EXCEPTION 'hosted onboarding principal is unavailable'
            USING ERRCODE = '23514';
    END IF;
    NEW.schema_version := 1;
    NEW.revision := 1;
    NEW.workspace_status := CASE WHEN EXISTS (
        SELECT 1 FROM attune.connectors AS connector
         WHERE connector.tenant_id = NEW.tenant_id
           AND connector.principal_id = NEW.owner_principal_id
           AND connector.provider = 'google'
           AND connector.status = 'active'
    ) THEN 'validated' ELSE 'not_started' END;
    NEW.channels_status := 'not_started';
    NEW.policy_status := 'not_started';
    NEW.activation_status := 'not_started';
    NEW.created_at := clock_timestamp();
    NEW.updated_at := NEW.created_at;
    RETURN NEW;
END
$function$;
CREATE TRIGGER hosted_onboarding_insert_guard
BEFORE INSERT ON attune.hosted_onboarding_states
FOR EACH ROW EXECUTE FUNCTION attune.enforce_hosted_onboarding_insert();

REVOKE ALL ON attune.hosted_onboarding_states FROM PUBLIC;
REVOKE ALL ON FUNCTION attune.enforce_hosted_onboarding_insert() FROM PUBLIC;
GRANT SELECT, INSERT ON attune.hosted_onboarding_states TO attune_control_plane;
