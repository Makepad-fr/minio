#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

set -a
source "${repo_root}/envs/production/.env.minio"
source /etc/makepad/minio/minio.env
set +a

mc_config_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${mc_config_dir}"
}
trap cleanup EXIT

mc_local() {
  docker run --rm --network host \
    -v "${mc_config_dir}:/root/.mc" \
    "${MAKEPAD_MINIO_MC_IMAGE:-minio/mc:RELEASE.2025-07-21T05-28-08Z}" "$@"
}

wait_for_minio() {
  for _ in $(seq 1 30); do
    if mc_local alias set local "http://127.0.0.1:${MAKEPAD_MINIO_PORT:-9000}" \
      "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "minio did not become ready in time" >&2
  return 1
}

write_policy() {
  local bucket=$1
  local target=$2

  cat > "${target}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket"
      ],
      "Effect": "Allow",
      "Resource": [
        "arn:aws:s3:::${bucket}"
      ]
    },
    {
      "Action": [
        "s3:AbortMultipartUpload",
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:ListMultipartUploadParts",
        "s3:PutObject"
      ],
      "Effect": "Allow",
      "Resource": [
        "arn:aws:s3:::${bucket}/*"
      ]
    }
  ]
}
EOF
}

wait_for_minio

mc_local mb --ignore-existing "local/${MAKEPAD_CATWLK_PRODUCTION_BUCKET}" >/dev/null
mc_local mb --ignore-existing "local/${MAKEPAD_CATWLK_CANARY_BUCKET}" >/dev/null

policy_host_dir="${mc_config_dir}/policies"
policy_container_dir="/root/.mc/policies"
mkdir -p "${policy_host_dir}"

write_policy "${MAKEPAD_CATWLK_PRODUCTION_BUCKET}" "${policy_host_dir}/catwlk-production.json"
write_policy "${MAKEPAD_CATWLK_CANARY_BUCKET}" "${policy_host_dir}/catwlk-canary.json"

mc_local admin policy info local catwlk-production >/dev/null 2>&1 \
  && mc_local admin policy remove local catwlk-production >/dev/null 2>&1 || true
mc_local admin policy info local catwlk-canary >/dev/null 2>&1 \
  && mc_local admin policy remove local catwlk-canary >/dev/null 2>&1 || true
mc_local admin policy create local catwlk-production "${policy_container_dir}/catwlk-production.json" >/dev/null
mc_local admin policy create local catwlk-canary "${policy_container_dir}/catwlk-canary.json" >/dev/null

mc_local admin user info local "${MAKEPAD_CATWLK_PRODUCTION_USER}" >/dev/null 2>&1 \
  && mc_local admin user remove local "${MAKEPAD_CATWLK_PRODUCTION_USER}" >/dev/null 2>&1 || true
mc_local admin user info local "${MAKEPAD_CATWLK_CANARY_USER}" >/dev/null 2>&1 \
  && mc_local admin user remove local "${MAKEPAD_CATWLK_CANARY_USER}" >/dev/null 2>&1 || true
mc_local admin user add local "${MAKEPAD_CATWLK_PRODUCTION_USER}" "${MAKEPAD_CATWLK_PRODUCTION_PASSWORD}" >/dev/null
mc_local admin user add local "${MAKEPAD_CATWLK_CANARY_USER}" "${MAKEPAD_CATWLK_CANARY_PASSWORD}" >/dev/null
mc_local admin policy attach local catwlk-production --user "${MAKEPAD_CATWLK_PRODUCTION_USER}" >/dev/null
mc_local admin policy attach local catwlk-canary --user "${MAKEPAD_CATWLK_CANARY_USER}" >/dev/null
