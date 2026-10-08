#!/usr/bin/env bash
set -euo pipefail
set +x
: "${MAKEPAD_BETACREW_PRODUCTION_USER:=betacrew-production-app}"
: "${MAKEPAD_BETACREW_PRODUCTION_PASSWORD:?set MAKEPAD_BETACREW_PRODUCTION_PASSWORD}"
[[ ${MAKEPAD_BETACREW_PRODUCTION_USER} == betacrew-production-app ]] || { echo 'Only the BetaCrew identity is supported' >&2; exit 1; }
[[ ${#MAKEPAD_BETACREW_PRODUCTION_PASSWORD} -ge 32 ]] || { echo 'BetaCrew password must be at least 32 characters' >&2; exit 1; }
[[ ${MAKEPAD_BETACREW_PRODUCTION_BUCKET:-betacrew-production} == betacrew-production && ${MAKEPAD_BETACREW_PRODUCTION_POLICY:-betacrew-production} == betacrew-production ]] || { echo 'Only the BetaCrew bucket and policy are supported' >&2; exit 1; }
container_name=${MINIO_CONTAINER_NAME:-minio-minio-1}
# Use the existing server's client and credentials. Do not expose credentials in
# host command arguments or start an unpinned privileged client on the host network.
{
  printf 'set +x\nexport MAKEPAD_BETACREW_PRODUCTION_PASSWORD=%q\n' "$MAKEPAD_BETACREW_PRODUCTION_PASSWORD"
  cat <<'INNER'
set -euo pipefail
: "${MINIO_ROOT_USER:?}" "${MINIO_ROOT_PASSWORD:?}"
config=$(mktemp -d)
chmod 700 "$config"
trap 'rm -rf -- "$config"' EXIT
export MC_CONFIG_DIR="$config"
mc alias set admin http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
# Listing must succeed before deciding whether a user exists. Never treat an
# unavailable service as permission to reset a potentially existing credential.
users=$(mc admin user list --json admin)
if [[ ${users//[[:space:]]/} == *'"accessKey":"betacrew-production-app"'* ]]; then
  info=$(mc admin user info --json admin betacrew-production-app)
  [[ ${info//[[:space:]]/} == *'"policyName":"betacrew-production"'* ]] || { echo 'Existing BetaCrew identity has unexpected policy scope' >&2; exit 1; }
  mc alias set app http://127.0.0.1:9000 betacrew-production-app "$MAKEPAD_BETACREW_PRODUCTION_PASSWORD" >/dev/null
  mc ls app/betacrew-production >/dev/null
else
  mc admin user add admin betacrew-production-app "$MAKEPAD_BETACREW_PRODUCTION_PASSWORD" >/dev/null
fi
cat > "$config/policy.json" <<'POLICY'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetBucketLocation","s3:ListBucket","s3:ListBucketMultipartUploads"],"Resource":["arn:aws:s3:::betacrew-production"]},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],"Resource":["arn:aws:s3:::betacrew-production/*"]}]}
POLICY
mc mb --ignore-existing admin/betacrew-production >/dev/null
mc anonymous set none admin/betacrew-production >/dev/null
mc admin policy create admin betacrew-production "$config/policy.json" >/dev/null
mc admin policy attach admin betacrew-production --user betacrew-production-app >/dev/null
mc alias set app http://127.0.0.1:9000 betacrew-production-app "$MAKEPAD_BETACREW_PRODUCTION_PASSWORD" >/dev/null
mc ls app/betacrew-production >/dev/null
INNER
} | docker exec -i "$container_name" bash -s
printf '%s\n' 'BetaCrew private bucket and retained scoped credential verified.'
