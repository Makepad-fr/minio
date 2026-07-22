#!/usr/bin/env bash
set -euo pipefail

: "${MINIO_ICEBERG_ACCESS_KEY:?set MINIO_ICEBERG_ACCESS_KEY}"
: "${MINIO_ICEBERG_SECRET_KEY:?set MINIO_ICEBERG_SECRET_KEY}"

container_name=${MINIO_CONTAINER_NAME:-minio-minio-1}
bucket=${MINIO_ICEBERG_BUCKET:-fashion-iceberg}
policy_name=${MINIO_ICEBERG_POLICY:-scraping-iceberg-writer}
mc_image=${MINIO_MC_IMAGE:-minio/mc:latest}

if [[ ! "${bucket}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  echo "Invalid MinIO bucket name: ${bucket}" >&2
  exit 1
fi

if ! docker inspect "${container_name}" >/dev/null 2>&1; then
  echo "MinIO container ${container_name} is not running." >&2
  exit 1
fi

minio_env=$(docker inspect "${container_name}" --format '{{range .Config.Env}}{{println .}}{{end}}')
minio_root_user=$(printf '%s\n' "${minio_env}" | sed -n 's/^MINIO_ROOT_USER=//p' | tail -n 1)
minio_root_password=$(printf '%s\n' "${minio_env}" | sed -n 's/^MINIO_ROOT_PASSWORD=//p' | tail -n 1)
: "${minio_root_user:?MINIO_ROOT_USER missing from ${container_name}}"
: "${minio_root_password:?MINIO_ROOT_PASSWORD missing from ${container_name}}"

policy_file=$(mktemp)
cleanup_policy() {
  if [[ -f "${policy_file}" ]]; then
    unlink "${policy_file}"
  fi
}
trap cleanup_policy EXIT
chmod 600 "${policy_file}"

printf '%s\n' "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Effect\": \"Allow\",
      \"Action\": [
        \"s3:GetBucketLocation\",
        \"s3:ListBucket\",
        \"s3:ListBucketMultipartUploads\"
      ],
      \"Resource\": [\"arn:aws:s3:::${bucket}\"]
    },
    {
      \"Effect\": \"Allow\",
      \"Action\": [
        \"s3:GetObject\",
        \"s3:PutObject\",
        \"s3:DeleteObject\",
        \"s3:AbortMultipartUpload\",
        \"s3:ListMultipartUploadParts\"
      ],
      \"Resource\": [\"arn:aws:s3:::${bucket}/*\"]
    }
  ]
}" > "${policy_file}"

docker run --rm --network host --entrypoint /bin/sh \
  -e MINIO_ROOT_USER="${minio_root_user}" \
  -e MINIO_ROOT_PASSWORD="${minio_root_password}" \
  -e MINIO_ICEBERG_ACCESS_KEY \
  -e MINIO_ICEBERG_SECRET_KEY \
  -e MINIO_ICEBERG_BUCKET="${bucket}" \
  -e MINIO_ICEBERG_POLICY="${policy_name}" \
  -v "${policy_file}:/policy.json:ro" \
  "${mc_image}" -c '
    set -eu
    mc alias set local http://127.0.0.1:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null
    mc mb --ignore-existing "local/${MINIO_ICEBERG_BUCKET}" >/dev/null
    mc admin policy create local "${MINIO_ICEBERG_POLICY}" /policy.json >/dev/null
    mc admin user add local "${MINIO_ICEBERG_ACCESS_KEY}" "${MINIO_ICEBERG_SECRET_KEY}" >/dev/null
    mc admin policy attach local "${MINIO_ICEBERG_POLICY}" --user "${MINIO_ICEBERG_ACCESS_KEY}" >/dev/null
    mc stat "local/${MINIO_ICEBERG_BUCKET}" >/dev/null
    mc admin user info local "${MINIO_ICEBERG_ACCESS_KEY}" >/dev/null
  '

echo "Provisioned MinIO bucket ${bucket} and user ${MINIO_ICEBERG_ACCESS_KEY}."
