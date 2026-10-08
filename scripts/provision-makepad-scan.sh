#!/usr/bin/env bash
set -euo pipefail
set +x
: "${MINIO_ROOT_USER:?}" "${MINIO_ROOT_PASSWORD:?}" "${SCAN_STORAGE_PASSWORD:?}"
[[ ${#SCAN_STORAGE_PASSWORD} -ge 32 ]]
root=$(cd "$(dirname "$0")/.." && pwd)
config=$(mktemp -d)
chmod 700 "$config"
trap 'rm -rf "$config"' EXIT
export MC_CONFIG_DIR="$config"
mc alias set scanner-admin http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb --ignore-existing scanner-admin/makepad-scan >/dev/null
mc anonymous set none scanner-admin/makepad-scan >/dev/null
mc admin policy create scanner-admin makepad-scan "$root/policies/makepad-scan.json" >/dev/null
if ! mc admin user info scanner-admin makepad-scan-app >/dev/null 2>&1; then
  mc admin user add scanner-admin makepad-scan-app "$SCAN_STORAGE_PASSWORD" >/dev/null
fi
mc admin policy attach scanner-admin makepad-scan --user makepad-scan-app >/dev/null
mc alias set scanner-app http://127.0.0.1:9000 makepad-scan-app "$SCAN_STORAGE_PASSWORD" >/dev/null
mc ls scanner-app/makepad-scan >/dev/null
printf '%s\n' 'Scanner private bucket and scoped credentials verified.'
