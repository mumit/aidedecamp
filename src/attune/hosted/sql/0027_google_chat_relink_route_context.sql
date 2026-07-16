-- A relink reuses the revoked destination UUID. Resolve that canonical UUID
-- before envelope encryption so the route's authenticated context matches the
-- durable row used by delivery.
DO $grant_link_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'GRANT attune_channel_link_executor TO %I', current_user
    );
END
$grant_link_owner$;
GRANT CREATE ON SCHEMA attune TO attune_channel_link_executor;
SET LOCAL ROLE attune_channel_link_executor;

CREATE OR REPLACE FUNCTION attune.resolve_google_chat_link_destination(
    p_secret_hash bytea, p_claim_hash bytea, p_candidate_id uuid
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    v_destination_id uuid;
BEGIN
    IF p_secret_hash IS NULL OR octet_length(p_secret_hash) <> 32
       OR p_claim_hash IS NULL OR octet_length(p_claim_hash) <> 32
       OR p_candidate_id IS NULL THEN
        RAISE EXCEPTION 'invalid channel destination resolution'
            USING ERRCODE = '22023';
    END IF;
    SELECT destination.id INTO v_destination_id
      FROM attune.hosted_channel_setup_transactions setup
      LEFT JOIN attune.hosted_channel_destinations destination
        ON destination.tenant_id = setup.tenant_id
       AND destination.owner_principal_id = setup.owner_principal_id
       AND destination.provider = 'google_chat'
       AND (
            (destination.status = 'pending_test'
             AND destination.route_version IS NULL)
            OR destination.status = 'revoked'
       )
     WHERE setup.provider = 'google_chat' AND setup.mechanism = 'link_code'
       AND setup.secret_hash = p_secret_hash AND setup.state = 'claimed'
       AND setup.claim_hash = p_claim_hash
       AND setup.claim_expires_at > clock_timestamp()
       AND setup.expires_at > clock_timestamp();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'channel link is unavailable' USING ERRCODE = 'P0002';
    END IF;
    RETURN COALESCE(v_destination_id, p_candidate_id);
END
$function$;

RESET ROLE;
REVOKE CREATE ON SCHEMA attune FROM attune_channel_link_executor;
DO $revoke_link_owner$
BEGIN
    EXECUTE pg_catalog.format(
        'REVOKE attune_channel_link_executor FROM %I', current_user
    );
END
$revoke_link_owner$;

ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA attune REVOKE ALL ON FUNCTIONS FROM PUBLIC;
