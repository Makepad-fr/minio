#!/usr/bin/env bash
set -euo pipefail
set +x
: "${MINIO_ROOT_USER:?}" "${MINIO_ROOT_PASSWORD:?}" "${VISITAKI_STORAGE_PASSWORD:?}"
[[ ${#VISITAKI_STORAGE_PASSWORD} -ge 32 ]]
root=$(cd "$(dirname "$0")/.." && pwd)
config=$(mktemp -d)
chmod 700 "$config"
trap 'rm -rf "$config"' EXIT
export MC_CONFIG_DIR="$config"
mc alias set visitaki-admin http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb --ignore-existing visitaki-admin/visitaki-preview >/dev/null
mc anonymous set none visitaki-admin/visitaki-preview >/dev/null
mc admin policy create visitaki-admin visitaki-preview "$root/policies/visitaki-preview.json" >/dev/null
if ! mc admin user info visitaki-admin visitaki-preview-app >/dev/null 2>&1; then
  mc admin user add visitaki-admin visitaki-preview-app "$VISITAKI_STORAGE_PASSWORD" >/dev/null
fi
mc admin policy attach visitaki-admin visitaki-preview --user visitaki-preview-app >/dev/null
mc alias set visitaki-client http://127.0.0.1:9000 visitaki-preview-app "$VISITAKI_STORAGE_PASSWORD" >/dev/null
mc ls visitaki-client/visitaki-preview >/dev/null
printf '%s\n' 'Visitaki preview private bucket and scoped credentials verified.'
