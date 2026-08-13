#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

set -a
source "${repo_root}/envs/production/.env.minio"
if [[ -r /etc/makepad/minio/minio.env ]]; then
  source /etc/makepad/minio/minio.env
fi
set +a

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER is required}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD is required}"
: "${MAKEPAD_BETACREW_PRODUCTION_BUCKET:?MAKEPAD_BETACREW_PRODUCTION_BUCKET is required}"
: "${MAKEPAD_BETACREW_PRODUCTION_USER:?MAKEPAD_BETACREW_PRODUCTION_USER is required}"
: "${MAKEPAD_BETACREW_PRODUCTION_PASSWORD:?MAKEPAD_BETACREW_PRODUCTION_PASSWORD is required}"

mc_config_dir="$(mktemp -d)"
cleanup() {
  docker run --rm -v "${mc_config_dir}:/target" alpine:3.22 sh -c 'find /target -mindepth 1 -delete' >/dev/null 2>&1 || true
  rmdir "${mc_config_dir}" 2>/dev/null || true
}
trap cleanup EXIT

mc_local() {
  docker run --rm --network host -v "${mc_config_dir}:/root/.mc" \
    "${MAKEPAD_MINIO_MC_IMAGE:-minio/mc:RELEASE.2025-07-21T05-28-08Z}" "$@"
}

for _ in $(seq 1 30); do
  if mc_local alias set local "http://127.0.0.1:${MAKEPAD_MINIO_PORT:-9000}" \
    "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1; then break; fi
  sleep 2
done
mc_local ready local >/dev/null
mc_local mb --ignore-existing "local/${MAKEPAD_BETACREW_PRODUCTION_BUCKET}" >/dev/null

policy_host_dir="${mc_config_dir}/policies"
mkdir -p "${policy_host_dir}"
cat > "${policy_host_dir}/betacrew-production.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
      "Effect": "Allow",
      "Resource": ["arn:aws:s3:::${MAKEPAD_BETACREW_PRODUCTION_BUCKET}"]
    },
    {
      "Action": ["s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetObject", "s3:ListMultipartUploadParts", "s3:PutObject"],
      "Effect": "Allow",
      "Resource": ["arn:aws:s3:::${MAKEPAD_BETACREW_PRODUCTION_BUCKET}/*"]
    }
  ]
}
EOF

mc_local admin policy info local betacrew-production >/dev/null 2>&1 \
  && mc_local admin policy remove local betacrew-production >/dev/null 2>&1 || true
mc_local admin policy create local betacrew-production /root/.mc/policies/betacrew-production.json >/dev/null
mc_local admin user info local "${MAKEPAD_BETACREW_PRODUCTION_USER}" >/dev/null 2>&1 \
  && mc_local admin user remove local "${MAKEPAD_BETACREW_PRODUCTION_USER}" >/dev/null 2>&1 || true
mc_local admin user add local "${MAKEPAD_BETACREW_PRODUCTION_USER}" "${MAKEPAD_BETACREW_PRODUCTION_PASSWORD}" >/dev/null
mc_local admin policy attach local betacrew-production --user "${MAKEPAD_BETACREW_PRODUCTION_USER}" >/dev/null

# Fail closed if the scoped account cannot use its bucket.
mc_local alias set betacrew "http://127.0.0.1:${MAKEPAD_MINIO_PORT:-9000}" \
  "${MAKEPAD_BETACREW_PRODUCTION_USER}" "${MAKEPAD_BETACREW_PRODUCTION_PASSWORD}" >/dev/null
mc_local ls "betacrew/${MAKEPAD_BETACREW_PRODUCTION_BUCKET}" >/dev/null
