DO $roles$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'attune_identity_provisioner'
    ) THEN
        CREATE ROLE attune_identity_provisioner
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'attune_identity_provisioning_executor'
    ) THEN
        CREATE ROLE attune_identity_provisioning_executor
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
    END IF;
END
$roles$;

CREATE FUNCTION attune.provision_initial_identity(
    p_subject_hash bytea, p_issuer text, p_tenant_slug text, p_region text
)
RETURNS TABLE (tenant_id uuid, principal_id uuid, created boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_tenant_id uuid;
    v_tenant_status text;
    v_principal_id uuid;
    v_principal_tenant_id uuid;
    v_principal_status text;
    v_principal_count integer;
BEGIN
    IF p_subject_hash IS NULL OR octet_length(p_subject_hash) <> 32
       OR p_issuer IS NULL
       OR p_issuer !~ '^https://securetoken[.]google[.]com/[a-z][a-z0-9-]{4,29}$'
       OR p_tenant_slug IS NULL
       OR p_tenant_slug !~ '^[a-z0-9][a-z0-9-]{1,62}$'
       OR p_region IS NULL
       OR p_region !~ '^[a-z][a-z0-9-]{1,62}$' THEN
        RAISE EXCEPTION 'invalid initial identity provisioning request'
            USING ERRCODE = '22023';
    END IF;

    -- Serialize the rare operator ceremony globally. It may create a tenant
    -- only together with that tenant's first principal.
    PERFORM pg_catalog.pg_advisory_xact_lock(214748301);

    SELECT tenant.id, tenant.status
      INTO v_tenant_id, v_tenant_status
      FROM attune.tenants AS tenant
     WHERE tenant.slug = p_tenant_slug;

    SELECT count(*), min(principal.tenant_id::text)::uuid,
           min(principal.id::text)::uuid, min(principal.status)
      INTO v_principal_count, v_principal_tenant_id,
           v_principal_id, v_principal_status
      FROM attune.principals AS principal
     WHERE principal.issuer = p_issuer
       AND principal.subject_hash = p_subject_hash;

    IF v_tenant_id IS NULL AND v_principal_count = 0 THEN
        INSERT INTO attune.tenants (slug, region)
        VALUES (p_tenant_slug, p_region)
        RETURNING tenants.id INTO v_tenant_id;

        INSERT INTO attune.principals (tenant_id, subject_hash, issuer)
        VALUES (v_tenant_id, p_subject_hash, p_issuer)
        RETURNING principals.id INTO v_principal_id;

        RETURN QUERY SELECT v_tenant_id, v_principal_id, true;
        RETURN;
    END IF;

    IF v_tenant_id IS NOT NULL
       AND v_tenant_status = 'active'
       AND v_principal_count = 1
       AND v_principal_tenant_id = v_tenant_id
       AND v_principal_status = 'active' THEN
        RETURN QUERY SELECT v_tenant_id, v_principal_id, false;
        RETURN;
    END IF;

    RAISE EXCEPTION 'initial identity provisioning conflicts with existing state'
        USING ERRCODE = '23505';
END
$function$;

REVOKE ALL ON FUNCTION
    attune.provision_initial_identity(bytea,text,text,text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.provision_initial_identity(bytea,text,text,text)
TO attune_identity_provisioner;
GRANT USAGE ON SCHEMA attune TO attune_identity_provisioner;

DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'GRANT attune_identity_provisioning_executor TO %I', current_user
    );
END
$grant_owner$;
GRANT USAGE, CREATE ON SCHEMA attune
TO attune_identity_provisioning_executor;
GRANT USAGE ON SCHEMA attune_ext TO attune_identity_provisioning_executor;
GRANT SELECT, INSERT ON attune.tenants, attune.principals
TO attune_identity_provisioning_executor;
ALTER FUNCTION attune.provision_initial_identity(bytea,text,text,text)
OWNER TO attune_identity_provisioning_executor;
REVOKE CREATE ON SCHEMA attune
FROM attune_identity_provisioning_executor;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'REVOKE attune_identity_provisioning_executor FROM %I', current_user
    );
END
$revoke_owner$;

ALTER DEFAULT PRIVILEGES IN SCHEMA attune
REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA attune
REVOKE ALL ON FUNCTIONS FROM PUBLIC;
