# Nuvio self-hosted backend

Native Kubernetes deployment of the official Nuvio self-host stack
(`NuvioMedia/self-host`), adapted from its Docker Compose files.

## Endpoint

- Account dashboard and backend: `https://nuvio.rbl.lol`
- Backend discovery: `https://nuvio.rbl.lol/.well-known/nuvio`
- Route: HTTPRoute `nuvio` → `network/external` Gateway, `sectionName: https`

## Components

| Component | Service |
|---|---|
| PostgreSQL | `db:5432` |
| GoTrue auth | `auth:9999` |
| PostgREST | `rest:3000` |
| Realtime | `realtime:4000` |
| Storage API + imgproxy sidecar | `storage:5000`, `imgproxy:5001` |
| Kong API gateway | `kong:8000` |
| Edge functions | `functions:9000` |
| Account dashboard | `account-dashboard:8080` |

Caddy was intentionally removed; the Gateway HTTPRoute does the public routing
directly to Kong and the dashboard.

## Secrets

Secrets are read by External Secrets Operator from the 1Password item
`Nuvio self-host` in the `home-ops` vault. The generated `nuvio-secrets`
Secret feeds every workload.

## Database bootstrap and migrations

- `nuvio-db-bootstrap` (sync wave 1): waits for PostgreSQL, creates the
  `supabase_functions_admin` role if missing, applies role passwords and JWT
  database settings.
- `nuvio-migrate` (sync wave 3): applies the Supabase/Nuvio SQL migrations and
  sets `nuvio_private.instance_settings.default_catalog_url`.
- `nuvio-seed-avatars` (sync wave 5): uploads the bundled avatar catalogue to
  the Storage API.

PostgreSQL uses `/var/lib/postgresql/data/pgdata` on a Longhorn volume because
Longhorn mounts contain `lost+found`. The image's `/etc/postgresql-custom`
directory is copied into a persistent config volume by an init container.

## Storage

The Storage API requires extended attributes. Longhorn RWX volumes are
NFS-backed and do not support them, so `storage-data` is a block-backed RWO
volume and `imgproxy` runs as a sidecar in the same pod.

## Backups

`nuvio-db-backup` runs daily at 03:15 Europe/Rome, writes a compressed
`pg_dump` to the `nuvio-backups` PVC, and keeps 14 days.

## Notes

- Public signup is currently open (`GOTRUE_DISABLE_SIGNUP=false`). Set it to
  `true` after creating the first account.
- The Apple TV build must support a custom backend URL. Use
  `https://nuvio.rbl.lol`; supported clients fetch the publishable key from
  `/.well-known/nuvio`.
- Upstream source revision is recorded in `UPSTREAM.txt`.
