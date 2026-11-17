BEGIN;

-- Dashboard edits include the timestamp of the settings snapshot they loaded.
-- Reject the write when another client has saved newer settings in the
-- meantime, rather than silently replacing those changes.
CREATE OR REPLACE FUNCTION public.sync_push_profile_settings_blob_guarded(
    p_profile_id integer,
    p_settings_json jsonb,
    p_platform text,
    p_expected_updated_at timestamptz
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid := public.get_sync_owner();
    v_current_updated_at timestamptz;
    v_saved_updated_at timestamptz;
BEGIN
    IF p_profile_id < 1 OR p_profile_id > 6 THEN
        RAISE EXCEPTION 'Invalid profile id' USING ERRCODE = '22023';
    END IF;

    SELECT settings.updated_at
    INTO v_current_updated_at
    FROM public.profile_settings_blobs AS settings
    WHERE settings.user_id = v_user_id
      AND settings.profile_id = p_profile_id
      AND settings.platform = p_platform
    FOR UPDATE;

    IF FOUND THEN
        IF p_expected_updated_at IS NULL
           OR v_current_updated_at IS DISTINCT FROM p_expected_updated_at THEN
            RAISE EXCEPTION 'Settings changed on another device. Reload and try again.'
                USING ERRCODE = '40001';
        END IF;
    ELSIF p_expected_updated_at IS NOT NULL THEN
        RAISE EXCEPTION 'Settings changed on another device. Reload and try again.'
            USING ERRCODE = '40001';
    END IF;

    PERFORM public.sync_push_profile_settings_blob(
        p_profile_id,
        p_settings_json,
        p_platform
    );

    SELECT settings.updated_at
    INTO v_saved_updated_at
    FROM public.profile_settings_blobs AS settings
    WHERE settings.user_id = v_user_id
      AND settings.profile_id = p_profile_id
      AND settings.platform = p_platform;

    RETURN v_saved_updated_at;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_push_profile_settings_blob_guarded(
    integer,
    jsonb,
    text,
    timestamptz
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.sync_push_profile_settings_blob_guarded(
    integer,
    jsonb,
    text,
    timestamptz
) TO authenticated, service_role;

COMMENT ON FUNCTION public.sync_push_profile_settings_blob_guarded(
    integer,
    jsonb,
    text,
    timestamptz
) IS
    'Writes a settings snapshot only when it still matches the version read by the dashboard, preventing a stale save from replacing newer client settings.';

-- Existing PostgREST containers should expose the new RPC immediately after
-- an upgrade, without requiring operators to restart the stack.
NOTIFY pgrst, 'reload schema';

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000009')
ON CONFLICT (version) DO NOTHING;

COMMIT;
