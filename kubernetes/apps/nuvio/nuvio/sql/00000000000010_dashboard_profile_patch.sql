BEGIN;

-- The account dashboard sends a sparse profile patch instead of replacing the
-- complete profile list. Keep the hosted RPC signature so the same dashboard
-- image works here, while limiting visual choices to self-hosted capabilities.
DROP FUNCTION IF EXISTS public.sync_patch_profile(
    integer,
    text,
    text,
    boolean,
    boolean,
    text,
    boolean,
    text,
    boolean,
    text,
    boolean,
    text,
    boolean
);

CREATE FUNCTION public.sync_patch_profile(
    p_profile_id integer,
    p_name text DEFAULT NULL,
    p_avatar_color_hex text DEFAULT NULL,
    p_uses_primary_addons boolean DEFAULT NULL,
    p_uses_primary_plugins boolean DEFAULT NULL,
    p_avatar_url text DEFAULT NULL,
    p_avatar_url_provided boolean DEFAULT false,
    p_avatar_id text DEFAULT NULL,
    p_avatar_id_provided boolean DEFAULT false,
    p_profile_background_id text DEFAULT NULL,
    p_profile_background_id_provided boolean DEFAULT false,
    p_profile_background_url text DEFAULT NULL,
    p_profile_background_url_provided boolean DEFAULT false
)
RETURNS TABLE (
    id uuid,
    user_id uuid,
    profile_index integer,
    name text,
    avatar_color_hex text,
    uses_primary_addons boolean,
    uses_primary_plugins boolean,
    avatar_id text,
    avatar_url text,
    profile_background_id text,
    profile_background_url text,
    created_at timestamptz,
    updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid := public.get_sync_owner();
    v_avatar_id text := NULLIF(btrim(COALESCE(p_avatar_id, '')), '');
    v_avatar_url text := NULLIF(btrim(COALESCE(p_avatar_url, '')), '');
    v_background_id text := NULLIF(btrim(COALESCE(p_profile_background_id, '')), '');
    v_background_url text := NULLIF(btrim(COALESCE(p_profile_background_url, '')), '');
BEGIN
    IF p_profile_id < 1 OR p_profile_id > 6 THEN
        RAISE EXCEPTION 'Invalid profile id' USING ERRCODE = '22023';
    END IF;

    IF p_name IS NOT NULL AND btrim(p_name) = '' THEN
        RAISE EXCEPTION 'Profile name cannot be empty' USING ERRCODE = '22023';
    END IF;

    IF p_avatar_url_provided
       AND v_avatar_url IS NOT NULL
       AND (
           char_length(v_avatar_url) > 2048
           OR v_avatar_url !~* '^https?://\S+$'
       ) THEN
        RAISE EXCEPTION 'Enter a valid http:// or https:// avatar image URL'
            USING ERRCODE = '22023';
    END IF;

    IF p_avatar_id_provided
       AND v_avatar_id IS NOT NULL
       AND NOT EXISTS (
           SELECT 1
           FROM public.avatar_catalog AS avatar
           WHERE avatar.id = v_avatar_id
             AND avatar.is_active
       ) THEN
        RAISE EXCEPTION 'This profile avatar is not available on this server'
            USING ERRCODE = '42501';
    END IF;

    IF p_profile_background_url_provided
       AND v_background_url IS NOT NULL
       AND (
           char_length(v_background_url) > 2048
           OR v_background_url !~* '^https?://\S+$'
       ) THEN
        RAISE EXCEPTION 'Enter a valid http:// or https:// profile background image URL'
            USING ERRCODE = '22023';
    END IF;

    IF (p_profile_background_id_provided AND v_background_id IS NOT NULL)
       OR (p_profile_background_url_provided AND v_background_url IS NOT NULL) THEN
        RAISE EXCEPTION 'Profile backgrounds are not available on self-hosted Nuvio'
            USING ERRCODE = '0A000';
    END IF;

    IF p_name IS NULL
       AND p_avatar_color_hex IS NULL
       AND p_uses_primary_addons IS NULL
       AND p_uses_primary_plugins IS NULL
       AND NOT p_avatar_url_provided
       AND NOT p_avatar_id_provided THEN
        RETURN QUERY
        SELECT
            profile.id,
            profile.user_id,
            profile.profile_index,
            profile.name,
            profile.avatar_color_hex,
            profile.uses_primary_addons,
            profile.uses_primary_plugins,
            profile.avatar_id,
            profile.avatar_url,
            NULL::text,
            NULL::text,
            profile.created_at,
            profile.updated_at
        FROM public.profiles AS profile
        WHERE profile.user_id = v_user_id
          AND profile.profile_index = p_profile_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Profile not found' USING ERRCODE = 'P0002';
        END IF;
        RETURN;
    END IF;

    RETURN QUERY
    UPDATE public.profiles AS profile
    SET
        name = CASE
            WHEN p_name IS NULL THEN profile.name
            ELSE btrim(p_name)
        END,
        avatar_color_hex = CASE
            WHEN p_avatar_color_hex IS NULL THEN profile.avatar_color_hex
            ELSE btrim(p_avatar_color_hex)
        END,
        uses_primary_addons = CASE
            WHEN profile.profile_index = 1 THEN false
            ELSE COALESCE(p_uses_primary_addons, profile.uses_primary_addons)
        END,
        uses_primary_plugins = CASE
            WHEN profile.profile_index = 1 THEN false
            ELSE COALESCE(p_uses_primary_plugins, profile.uses_primary_plugins)
        END,
        avatar_id = CASE
            WHEN p_avatar_url_provided AND v_avatar_url IS NOT NULL THEN NULL
            WHEN p_avatar_id_provided THEN v_avatar_id
            WHEN p_avatar_url_provided THEN NULL
            ELSE profile.avatar_id
        END,
        avatar_url = CASE
            WHEN p_avatar_url_provided THEN v_avatar_url
            WHEN p_avatar_id_provided THEN NULL
            ELSE profile.avatar_url
        END,
        updated_at = now()
    WHERE profile.user_id = v_user_id
      AND profile.profile_index = p_profile_id
    RETURNING
        profile.id,
        profile.user_id,
        profile.profile_index,
        profile.name,
        profile.avatar_color_hex,
        profile.uses_primary_addons,
        profile.uses_primary_plugins,
        profile.avatar_id,
        profile.avatar_url,
        NULL::text,
        NULL::text,
        profile.created_at,
        profile.updated_at;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profile not found' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_patch_profile(
    integer,
    text,
    text,
    boolean,
    boolean,
    text,
    boolean,
    text,
    boolean,
    text,
    boolean,
    text,
    boolean
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.sync_patch_profile(
    integer,
    text,
    text,
    boolean,
    boolean,
    text,
    boolean,
    text,
    boolean,
    text,
    boolean,
    text,
    boolean
) TO authenticated, service_role;

COMMENT ON FUNCTION public.sync_patch_profile(
    integer,
    text,
    text,
    boolean,
    boolean,
    text,
    boolean,
    text,
    boolean,
    text,
    boolean,
    text,
    boolean
) IS
    'Updates only profile fields explicitly changed by the account dashboard. Self-hosted servers accept catalog or custom avatars and do not expose membership backgrounds.';

-- Existing PostgREST containers should expose the new RPC immediately after
-- an upgrade, without requiring operators to restart the stack.
NOTIFY pgrst, 'reload schema';

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000010')
ON CONFLICT (version) DO NOTHING;

COMMIT;
