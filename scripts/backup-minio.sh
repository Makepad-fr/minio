#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

set -a
source "${repo_root}/envs/production/.env.minio"
source /etc/makepad/minio/minio.env
source /etc/makepad/backups/restic-minio.env
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

mc_local alias set local "http://127.0.0.1:${MAKEPAD_MINIO_PORT:-9000}" \
  "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_root="${MAKEPAD_MINIO_BACKUP_PATH}/${timestamp}"
mkdir -p "${backup_root}"

mc_local mirror --overwrite "local/${MAKEPAD_CATWLK_PRODUCTION_BUCKET}" "${backup_root}/catwlk-production" >/dev/null
mc_local mirror --overwrite "local/${MAKEPAD_CATWLK_CANARY_BUCKET}" "${backup_root}/catwlk-canary" >/dev/null

restic backup "${backup_root}"
restic forget --prune \
  --keep-daily "${MAKEPAD_MINIO_RETENTION_DAILY:-30}" \
  --keep-monthly "${MAKEPAD_MINIO_RETENTION_MONTHLY:-12}"

find "${MAKEPAD_MINIO_BACKUP_PATH}" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
