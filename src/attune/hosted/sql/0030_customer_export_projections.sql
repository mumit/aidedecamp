-- Exact, claim-bound customer export projections. No object publication or
-- completion transition is introduced by this migration.
CREATE FUNCTION attune.read_customer_export_records(
    p_export_id uuid, p_run_id uuid
)
RETURNS TABLE (member_name text, sort_key text, record jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_job record;
    v_records bigint;
BEGIN
    IF NOT pg_catalog.pg_has_role(session_user, 'attune_export', 'MEMBER') THEN
        RAISE EXCEPTION 'export reader is unauthorized' USING ERRCODE = '42501';
    END IF;
    SELECT job.tenant_id, job.requested_by, job.scope ->> 'name' AS scope_name
      INTO v_job
      FROM attune.export_jobs AS job
     WHERE job.id = p_export_id
       AND job.state = 'running'
       AND job.lease_run_id = p_run_id
       AND job.lease_expires_at > clock_timestamp()
       AND EXISTS (
            SELECT 1
              FROM attune.hosted_onboarding_states owner_state
             WHERE owner_state.tenant_id = job.tenant_id
               AND owner_state.owner_principal_id = job.requested_by
       );
    IF NOT FOUND THEN
        RAISE EXCEPTION 'active export claim is required' USING ERRCODE = '42501';
    END IF;

    IF v_job.scope_name = 'account' THEN
        SELECT
            1
            + (SELECT count(*) FROM attune.principals p
                WHERE p.tenant_id = v_job.tenant_id AND p.id = v_job.requested_by)
            + (SELECT count(*) FROM attune.connectors c
                WHERE c.tenant_id = v_job.tenant_id AND c.principal_id = v_job.requested_by)
            + (SELECT count(*) FROM attune.installations i
                WHERE i.tenant_id = v_job.tenant_id AND EXISTS (
                    SELECT 1 FROM attune.connectors c
                     WHERE c.tenant_id = i.tenant_id AND c.installation_id = i.id
                       AND c.principal_id = v_job.requested_by))
            + (SELECT count(*) FROM attune.policies p WHERE p.tenant_id = v_job.tenant_id)
            + (SELECT count(*) FROM attune.autonomy_grants a
                WHERE a.tenant_id = v_job.tenant_id AND a.principal_id = v_job.requested_by)
            + (SELECT count(*) FROM attune.hosted_onboarding_states o
                WHERE o.tenant_id = v_job.tenant_id AND o.owner_principal_id = v_job.requested_by)
            + (SELECT count(*) FROM attune.hosted_channel_preferences p
                WHERE p.tenant_id = v_job.tenant_id AND p.owner_principal_id = v_job.requested_by)
            + (SELECT count(*) FROM attune.hosted_channel_destinations d
                WHERE d.tenant_id = v_job.tenant_id AND d.owner_principal_id = v_job.requested_by)
          INTO v_records;
        IF v_records > 100000 THEN
            RAISE EXCEPTION 'export projection exceeds record limit' USING ERRCODE = '54000';
        END IF;

        RETURN QUERY SELECT 'account.jsonl', 'tenant:' || tenant.id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'tenant',
                'data', pg_catalog.jsonb_build_object(
                    'id', tenant.id, 'slug', tenant.slug, 'status', tenant.status,
                    'region', tenant.region, 'created_at', tenant.created_at,
                    'updated_at', tenant.updated_at))
          FROM attune.tenants tenant WHERE tenant.id = v_job.tenant_id;
        RETURN QUERY SELECT 'account.jsonl', 'principal:' || principal.id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'principal',
                'data', pg_catalog.jsonb_build_object(
                    'id', principal.id, 'issuer', principal.issuer,
                    'status', principal.status, 'created_at', principal.created_at,
                    'updated_at', principal.updated_at))
          FROM attune.principals principal
         WHERE principal.tenant_id = v_job.tenant_id
           AND principal.id = v_job.requested_by;
        RETURN QUERY SELECT 'account.jsonl', 'installation:' || installation.id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'installation',
                'data', pg_catalog.jsonb_build_object(
                    'id', installation.id, 'provider', installation.provider,
                    'kind', installation.kind, 'status', installation.status,
                    'created_at', installation.created_at,
                    'updated_at', installation.updated_at))
          FROM attune.installations installation
         WHERE installation.tenant_id = v_job.tenant_id AND EXISTS (
            SELECT 1 FROM attune.connectors connector
             WHERE connector.tenant_id = installation.tenant_id
               AND connector.installation_id = installation.id
               AND connector.principal_id = v_job.requested_by);
        RETURN QUERY SELECT 'account.jsonl', 'connector:' || connector.id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'connector',
                'data', pg_catalog.jsonb_build_object(
                    'id', connector.id, 'principal_id', connector.principal_id,
                    'installation_id', connector.installation_id,
                    'provider', connector.provider,
                    'granted_scopes', connector.granted_scopes,
                    'status', connector.status, 'version', connector.version,
                    'created_at', connector.created_at,
                    'updated_at', connector.updated_at))
          FROM attune.connectors connector
         WHERE connector.tenant_id = v_job.tenant_id
           AND connector.principal_id = v_job.requested_by;
        RETURN QUERY SELECT 'account.jsonl', 'policy:' || policy.id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'policy',
                'data', pg_catalog.jsonb_build_object(
                    'id', policy.id, 'version', policy.version,
                    'active', policy.active,
                    'created_at', policy.created_at))
          FROM attune.policies policy WHERE policy.tenant_id = v_job.tenant_id;
        RETURN QUERY SELECT 'account.jsonl', 'autonomy_grant:' || grant_row.id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'autonomy_grant',
                'data', pg_catalog.jsonb_build_object(
                    'id', grant_row.id, 'principal_id', grant_row.principal_id,
                    'capability', grant_row.capability, 'domain', grant_row.domain,
                    'maximum_risk', grant_row.maximum_risk,
                    'policy_version', grant_row.policy_version,
                    'created_at', grant_row.created_at,
                    'revoked_at', grant_row.revoked_at))
          FROM attune.autonomy_grants grant_row
         WHERE grant_row.tenant_id = v_job.tenant_id
           AND grant_row.principal_id = v_job.requested_by;
        RETURN QUERY SELECT 'account.jsonl', 'onboarding:' || state.owner_principal_id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'onboarding',
                'data', pg_catalog.jsonb_build_object(
                    'owner_principal_id', state.owner_principal_id,
                    'schema_version', state.schema_version, 'revision', state.revision,
                    'workspace_status', state.workspace_status,
                    'channels_status', state.channels_status,
                    'policy_status', state.policy_status,
                    'activation_status', state.activation_status,
                    'created_at', state.created_at, 'updated_at', state.updated_at))
          FROM attune.hosted_onboarding_states state
         WHERE state.tenant_id = v_job.tenant_id
           AND state.owner_principal_id = v_job.requested_by;
        RETURN QUERY SELECT 'account.jsonl', 'channel_preferences:' || preference.owner_principal_id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'channel_preferences',
                'data', pg_catalog.jsonb_build_object(
                    'owner_principal_id', preference.owner_principal_id,
                    'schema_version', preference.schema_version,
                    'revision', preference.revision,
                    'interaction_channels', preference.interaction_channels,
                    'brief_channels', preference.brief_channels,
                    'created_at', preference.created_at,
                    'updated_at', preference.updated_at))
          FROM attune.hosted_channel_preferences preference
         WHERE preference.tenant_id = v_job.tenant_id
           AND preference.owner_principal_id = v_job.requested_by;
        RETURN QUERY SELECT 'account.jsonl', 'channel_destination:' || destination.id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'channel_destination',
                'data', pg_catalog.jsonb_build_object(
                    'id', destination.id,
                    'owner_principal_id', destination.owner_principal_id,
                    'installation_id', destination.installation_id,
                    'provider', destination.provider,
                    'visibility', destination.visibility,
                    'status', destination.status,
                    'ingress_verified_at', destination.ingress_verified_at,
                    'delivery_verified_at', destination.delivery_verified_at,
                    'version', destination.version,
                    'created_at', destination.created_at,
                    'updated_at', destination.updated_at))
          FROM attune.hosted_channel_destinations destination
         WHERE destination.tenant_id = v_job.tenant_id
           AND destination.owner_principal_id = v_job.requested_by;

    ELSIF v_job.scope_name = 'conversations' THEN
        SELECT (SELECT count(*) FROM attune.conversations c
                 WHERE c.tenant_id = v_job.tenant_id AND c.principal_id = v_job.requested_by)
             + (SELECT count(*) FROM attune.conversation_turns t
                 JOIN attune.conversations c ON c.tenant_id = t.tenant_id AND c.id = t.conversation_id
                 WHERE c.tenant_id = v_job.tenant_id AND c.principal_id = v_job.requested_by)
          INTO v_records;
        IF v_records > 100000 THEN RAISE EXCEPTION 'export projection exceeds record limit' USING ERRCODE = '54000'; END IF;
        RETURN QUERY SELECT 'conversations.jsonl', 'conversation:' || c.id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'conversation',
                'data', pg_catalog.jsonb_build_object(
                    'id', c.id, 'installation_id', c.installation_id,
                    'principal_id', c.principal_id, 'surface', c.surface,
                    'created_at', c.created_at, 'updated_at', c.updated_at))
          FROM attune.conversations c WHERE c.tenant_id = v_job.tenant_id
           AND c.principal_id = v_job.requested_by;
        RETURN QUERY SELECT 'conversations.jsonl',
            'conversation_turn:' || t.conversation_id::text || ':' || pg_catalog.lpad(t.sequence::text, 20, '0'),
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'conversation_turn',
                'data', pg_catalog.jsonb_build_object(
                    'conversation_id', t.conversation_id, 'sequence', t.sequence,
                    'actor_type', t.actor_type, 'content', t.content,
                    'created_at', t.created_at))
          FROM attune.conversation_turns t JOIN attune.conversations c
            ON c.tenant_id = t.tenant_id AND c.id = t.conversation_id
         WHERE c.tenant_id = v_job.tenant_id AND c.principal_id = v_job.requested_by;

    ELSIF v_job.scope_name = 'memories' THEN
        SELECT count(*) INTO v_records FROM attune.memories memory
         WHERE memory.tenant_id = v_job.tenant_id
           AND memory.principal_id = v_job.requested_by AND memory.deleted_at IS NULL;
        IF v_records > 100000 THEN RAISE EXCEPTION 'export projection exceeds record limit' USING ERRCODE = '54000'; END IF;
        RETURN QUERY SELECT 'memories.jsonl', 'memory:' || memory.id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'memory',
                'data', pg_catalog.jsonb_build_object(
                    'id', memory.id, 'principal_id', memory.principal_id,
                    'creator_id', memory.creator_id, 'content', memory.content,
                    'source_class', memory.source_class,
                    'confidence', memory.confidence,
                    'created_at', memory.created_at, 'updated_at', memory.updated_at))
          FROM attune.memories memory WHERE memory.tenant_id = v_job.tenant_id
           AND memory.principal_id = v_job.requested_by AND memory.deleted_at IS NULL;

    ELSIF v_job.scope_name = 'activity' THEN
        SELECT (SELECT count(*) FROM attune.audit_events a WHERE a.tenant_id = v_job.tenant_id)
             + (SELECT count(*) FROM attune.usage_records u WHERE u.tenant_id = v_job.tenant_id)
          INTO v_records;
        IF v_records > 100000 THEN RAISE EXCEPTION 'export projection exceeds record limit' USING ERRCODE = '54000'; END IF;
        RETURN QUERY SELECT 'activity.jsonl', 'audit_event:' || pg_catalog.lpad(a.sequence::text, 20, '0'),
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'audit_event',
                'data', pg_catalog.jsonb_build_object(
                    'sequence', a.sequence, 'occurred_at', a.occurred_at,
                    'actor_type', a.actor_type, 'action', a.action,
                    'outcome', a.outcome, 'target_type', a.target_type))
          FROM attune.audit_events a WHERE a.tenant_id = v_job.tenant_id;
        RETURN QUERY SELECT 'activity.jsonl', 'usage_record:' || u.id::text,
            pg_catalog.jsonb_build_object('schema_version', 1, 'kind', 'usage_record',
                'data', pg_catalog.jsonb_build_object(
                    'id', u.id, 'category', u.category, 'provider', u.provider,
                    'units', u.units, 'occurred_at', u.occurred_at))
          FROM attune.usage_records u WHERE u.tenant_id = v_job.tenant_id;
    ELSE
        RAISE EXCEPTION 'unsupported export scope' USING ERRCODE = '22023';
    END IF;
END
$function$;

DO $grant_owner$
BEGIN
    EXECUTE pg_catalog.format('GRANT attune_export_coordinator TO %I', current_user);
END
$grant_owner$;
GRANT USAGE, CREATE ON SCHEMA attune TO attune_export_coordinator;
GRANT SELECT ON attune.tenants, attune.principals, attune.installations,
    attune.connectors, attune.policies, attune.autonomy_grants,
    attune.hosted_onboarding_states, attune.hosted_channel_preferences,
    attune.hosted_channel_destinations, attune.conversations,
    attune.conversation_turns, attune.memories, attune.audit_events,
    attune.usage_records TO attune_export_coordinator;
ALTER FUNCTION attune.read_customer_export_records(uuid, uuid)
OWNER TO attune_export_coordinator;
REVOKE CREATE ON SCHEMA attune FROM attune_export_coordinator;
DO $revoke_owner$
BEGIN
    EXECUTE pg_catalog.format('REVOKE attune_export_coordinator FROM %I', current_user);
END
$revoke_owner$;
REVOKE ALL ON FUNCTION attune.read_customer_export_records(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION attune.read_customer_export_records(uuid, uuid)
TO attune_export;
