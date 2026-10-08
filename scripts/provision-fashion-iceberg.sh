#!/usr/bin/env bash
set -euo pipefail
set +x
: "${MINIO_ICEBERG_ACCESS_KEY:?set MINIO_ICEBERG_ACCESS_KEY}"
: "${MINIO_ICEBERG_SECRET_KEY:?set MINIO_ICEBERG_SECRET_KEY}"
[[ ${MINIO_ICEBERG_ACCESS_KEY} == scraping-iceberg ]] || { echo 'Only the Fashion identity is supported' >&2; exit 1; }
[[ ${#MINIO_ICEBERG_SECRET_KEY} -ge 32 ]] || { echo 'Fashion password must be at least 32 characters' >&2; exit 1; }
[[ ${MINIO_ICEBERG_BUCKET:-fashion-iceberg} == fashion-iceberg && ${MINIO_ICEBERG_POLICY:-scraping-iceberg-writer} == scraping-iceberg-writer ]] || { echo 'Only the Fashion bucket and policy are supported' >&2; exit 1; }
container_name=${MINIO_CONTAINER_NAME:-minio-minio-1}
# Use the existing server's client and credentials. Do not expose credentials in
# host command arguments or start an unpinned privileged client on the host network.
{
  printf 'set +x\nexport MINIO_ICEBERG_SECRET_KEY=%q\n' "$MINIO_ICEBERG_SECRET_KEY"
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
if [[ ${users//[[:space:]]/} == *'"accessKey":"scraping-iceberg"'* ]]; then
  info=$(mc admin user info --json admin scraping-iceberg)
  [[ ${info//[[:space:]]/} == *'"policyName":"scraping-iceberg-writer"'* ]] || { echo 'Existing Fashion identity has unexpected policy scope' >&2; exit 1; }
  mc alias set app http://127.0.0.1:9000 scraping-iceberg "$MINIO_ICEBERG_SECRET_KEY" >/dev/null
  mc ls app/fashion-iceberg >/dev/null
else
  mc admin user add admin scraping-iceberg "$MINIO_ICEBERG_SECRET_KEY" >/dev/null
fi
cat > "$config/policy.json" <<'POLICY'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetBucketLocation","s3:ListBucket","s3:ListBucketMultipartUploads"],"Resource":["arn:aws:s3:::fashion-iceberg"]},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],"Resource":["arn:aws:s3:::fashion-iceberg/*"]}]}
POLICY
mc mb --ignore-existing admin/fashion-iceberg >/dev/null
mc anonymous set none admin/fashion-iceberg >/dev/null
mc admin policy create admin scraping-iceberg-writer "$config/policy.json" >/dev/null
mc admin policy attach admin scraping-iceberg-writer --user scraping-iceberg >/dev/null
mc alias set app http://127.0.0.1:9000 scraping-iceberg "$MINIO_ICEBERG_SECRET_KEY" >/dev/null
mc ls app/fashion-iceberg >/dev/null
INNER
} | docker exec -i "$container_name" bash -s
printf '%s\n' 'Fashion private bucket and retained scoped credential verified.'
