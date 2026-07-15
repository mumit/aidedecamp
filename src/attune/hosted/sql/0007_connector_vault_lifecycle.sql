CREATE FUNCTION attune.store_connector_credential(
    p_intent_id uuid,
    p_ciphertext bytea,
    p_nonce bytea,
    p_wrapped_dek bytea,
    p_key_resource text,
    p_format_version integer
)
RETURNS TABLE (credential_id uuid, credential_version integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE
    intent attune.credential_intents%ROWTYPE;
    next_version integer;
    new_id uuid;
BEGIN
    IF octet_length(p_ciphertext) NOT BETWEEN 17 AND 131072
       OR octet_length(p_nonce) <> 12
       OR octet_length(p_wrapped_dek) NOT BETWEEN 1 AND 65536
       OR length(p_key_resource) NOT BETWEEN 1 AND 512
       OR p_format_version <> 1 THEN
        RAISE EXCEPTION 'invalid encrypted credential envelope'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO intent FROM attune.credential_intents
     WHERE id = p_intent_id AND operation = 'install' AND state = 'leased'
       AND expires_at > clock_timestamp()
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    SELECT COALESCE(MAX(existing.credential_version), 0) + 1
      INTO next_version
      FROM attune.connector_credentials AS existing
     WHERE existing.tenant_id = intent.tenant_id
       AND existing.connector_id = intent.connector_id;
    UPDATE attune.connector_credentials AS existing
       SET status = 'superseded'
     WHERE existing.tenant_id = intent.tenant_id
       AND existing.connector_id = intent.connector_id
       AND existing.status = 'active';
    INSERT INTO attune.connector_credentials (
        tenant_id, connector_id, credential_version, format_version,
        ciphertext, nonce, wrapped_dek, key_resource
    ) VALUES (
        intent.tenant_id, intent.connector_id, next_version, p_format_version,
        p_ciphertext, p_nonce, p_wrapped_dek, p_key_resource
    ) RETURNING id INTO new_id;
    UPDATE attune.connectors
       SET credential_ref = new_id, status = 'active', updated_at = clock_timestamp()
     WHERE tenant_id = intent.tenant_id AND id = intent.connector_id;
    UPDATE attune.credential_intents
       SET state = 'consumed', lease_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE tenant_id = intent.tenant_id AND id = intent.id;
    RETURN QUERY SELECT new_id, next_version;
END $function$;

CREATE FUNCTION attune.revoke_connector_credential(p_intent_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $function$
DECLARE intent attune.credential_intents%ROWTYPE;
BEGIN
    SELECT * INTO intent FROM attune.credential_intents
     WHERE id = p_intent_id AND operation = 'revoke' AND state = 'leased'
       AND expires_at > clock_timestamp()
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    UPDATE attune.connector_credentials
       SET status = 'revoked', revoked_at = clock_timestamp()
     WHERE tenant_id = intent.tenant_id AND connector_id = intent.connector_id
       AND status = 'active';
    UPDATE attune.connectors
       SET status = 'revoked', updated_at = clock_timestamp()
     WHERE tenant_id = intent.tenant_id AND id = intent.connector_id;
    UPDATE attune.credential_intents
       SET state = 'consumed', lease_expires_at = NULL,
           updated_at = clock_timestamp()
     WHERE tenant_id = intent.tenant_id AND id = intent.id;
    RETURN true;
END $function$;

REVOKE ALL ON FUNCTION
    attune.store_connector_credential(uuid,bytea,bytea,bytea,text,integer)
FROM PUBLIC;
REVOKE ALL ON FUNCTION attune.revoke_connector_credential(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    attune.store_connector_credential(uuid,bytea,bytea,bytea,text,integer)
TO attune_secret_broker;
GRANT EXECUTE ON FUNCTION attune.revoke_connector_credential(uuid)
TO attune_secret_broker;
