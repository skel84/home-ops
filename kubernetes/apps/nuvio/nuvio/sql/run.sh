#!/usr/bin/env bash
set -euo pipefail

export PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
PGHOST="${PGHOST:-db}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
PSQL=(psql -v ON_ERROR_STOP=1 -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE")

echo "waiting for postgres at ${PGHOST}"
until pg_isready -h "$PGHOST" -p 5432 -U "$PGUSER" >/dev/null 2>&1; do
  sleep 2
done

schema_exists="$("${PSQL[@]}" -Atqc "select to_regclass('nuvio_migrations.schema_migrations') is not null")"

if [ "$schema_exists" != "t" ]; then
  # Supabase base schema, followed by Nuvio's baseline and auth trigger.
  psql -v ON_ERROR_STOP=1 -h db -U supabase_admin -d postgres -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_functions_admin') THEN CREATE USER supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION; END IF; END \$\$;"
  
  for file in \
    00-webhooks.sql \
    01-roles.sql \
    02-jwt.sql \
    03-_supabase.sql \
    04-logs.sql \
    05-pooler.sql \
    06-realtime.sql \
    00000000000000_baseline.sql \
    00000000000001_auth_trigger.sql
  do
    echo "applying ${file}"
    "${PSQL[@]}" -f "/sql/${file}"
  done
fi

# Remaining Nuvio migrations. Each file is idempotent at the version level and
# records itself in nuvio_migrations.schema_migrations.
for file in /sql/0000000000000[2-9]_*.sql /sql/0000000000001[01]_*.sql; do
  [ -e "$file" ] || continue
  version="$(basename "$file" | cut -d_ -f1)"
  applied="$("${PSQL[@]}" -Atqc "select exists(select 1 from nuvio_migrations.schema_migrations where version = '${version}')")"
  if [ "$applied" != "t" ]; then
    echo "applying $(basename "$file")"
    "${PSQL[@]}" -f "$file"
  fi
done

"${PSQL[@]}" -v catalog_url="${DEFAULT_CATALOG_URL:-https://catalog.nuvio.tv/manifest.json}" <<'SQL'
INSERT INTO nuvio_private.instance_settings (key, value, updated_at)
VALUES ('default_catalog_url', :'catalog_url', now())
ON CONFLICT (key) DO UPDATE
SET value = excluded.value,
    updated_at = excluded.updated_at;
SQL

echo "nuvio database migrations complete"
