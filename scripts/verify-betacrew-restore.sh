#!/usr/bin/env bash
set -euo pipefail

: "${BETACREW_RESTORE_CONFIRM:?set BETACREW_RESTORE_CONFIRM=write-probe-backup-and-restore}"
[[ "${BETACREW_RESTORE_CONFIRM}" == write-probe-backup-and-restore ]] || { echo "Restore drill requires the exact confirmation value." >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
set -a
source "${repo_root}/envs/production/.env.minio"
source /etc/makepad/minio/minio.env
source /etc/makepad/backups/restic-minio.env
set +a

work_dir=$(mktemp -d)
mc_config_dir=${work_dir}/mc
restore_dir=${work_dir}/restore
mkdir -p "${mc_config_dir}" "${restore_dir}"
probe_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
probe_key=".backup-restore-probe/${probe_id}.txt"
printf 'BetaCrew backup restore probe %s\n' "${probe_id}" > "${work_dir}/probe.txt"

mc_local() {
  docker run --rm --network host \
    -v "${mc_config_dir}:/root/.mc" \
    -v "${work_dir}:/work" \
    "${MAKEPAD_MINIO_MC_IMAGE:-minio/mc:RELEASE.2025-07-21T05-28-08Z}" "$@"
}
cleanup() {
  mc_local rm --force "local/${MAKEPAD_BETACREW_PRODUCTION_BUCKET}/${probe_key}" >/dev/null 2>&1 || true
  find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true
  rmdir "${work_dir}" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

mc_local alias set local "http://127.0.0.1:${MAKEPAD_MINIO_PORT:-9000}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null
mc_local cp /work/probe.txt "local/${MAKEPAD_BETACREW_PRODUCTION_BUCKET}/${probe_key}" >/dev/null
"${repo_root}/scripts/backup-minio.sh" >/dev/null
restic restore latest --target "${restore_dir}" >/dev/null

restored_probe=$(find "${restore_dir}" -type f -path "*/betacrew-production/${probe_key}" -print -quit)
[[ -n "${restored_probe}" ]] || { echo "BetaCrew restore probe was not present in the restored snapshot." >&2; exit 1; }
cmp "${work_dir}/probe.txt" "${restored_probe}"
echo "BetaCrew MinIO backup and restore drill passed."
