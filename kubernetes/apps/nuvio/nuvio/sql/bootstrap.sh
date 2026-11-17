#!/usr/bin/env bash
set -euo pipefail

export PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"

echo "waiting for postgres at db"
until pg_isready -h db -p 5432 -U supabase_admin >/dev/null 2>&1; do
  sleep 2
done

# Passwords and JWT database settings must exist before PostgREST, Storage and
# the other Supabase services start. These files are idempotent.
psql -v ON_ERROR_STOP=1 -h db -U supabase_admin -d postgres -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_functions_admin') THEN CREATE USER supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION; END IF; END \$\$;"

for file in 01-roles.sql 02-jwt.sql; do
  echo "applying ${file}"
  psql -v ON_ERROR_STOP=1 -h db -U supabase_admin -d postgres -f "/sql/${file}"
done

echo "database bootstrap complete"
