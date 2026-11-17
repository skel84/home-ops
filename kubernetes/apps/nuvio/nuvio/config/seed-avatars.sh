#!/bin/sh
set -eu

: "${SERVICE_ROLE_KEY:?SERVICE_ROLE_KEY is required}"

BASE_URL="${BASE_URL:-http://kong:8000}"
UPSTREAM="${UPSTREAM:-https://raw.githubusercontent.com/NuvioMedia/self-host/main/assets/avatars}"

while IFS= read -r name; do
  [ -n "$name" ] || continue
  public_url="${BASE_URL}/storage/v1/object/public/avatars/${name}"
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "$public_url")" = "200" ]; then
    continue
  fi

  tmp="/tmp/${name}"
  curl -fsSL "${UPSTREAM}/${name}" -o "$tmp"
  curl -fsS -o /dev/null \
    -X POST \
    -H "apikey: ${SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
    -H "Content-Type: image/png" \
    -H "Cache-Control: public, max-age=31536000, immutable" \
    -H "x-upsert: true" \
    --data-binary "@${tmp}" \
    "${BASE_URL}/storage/v1/object/avatars/${name}"
  rm -f "$tmp"
  echo "uploaded ${name}"
done < /config/avatars.txt

echo "avatar seeding complete"
