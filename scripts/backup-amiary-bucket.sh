#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/amiary-backup-lib.sh
source "${script_dir}/amiary-backup-lib.sh"

[[ $# -eq 0 ]] || die "usage: scripts/backup-amiary-bucket.sh"
validate_backup_minio_config
validate_storage_config
validate_retention_days

container_uid=$(stat_uid "${AMIARY_MINIO_BACKUP_CREDENTIALS_FILE}")
container_gid=$(stat_gid "${AMIARY_MINIO_BACKUP_CREDENTIALS_FILE}")
validate_owned_directory "${AMIARY_BACKUP_ROOT}" "backup root"

snapshots_root="${AMIARY_BACKUP_ROOT}/snapshots"
staging_root="${AMIARY_BACKUP_ROOT}/.staging"
operation_lock="${AMIARY_BACKUP_ROOT}/.operation.lock"
mkdir -p "${snapshots_root}" "${staging_root}"
[[ -d "${snapshots_root}" && ! -L "${snapshots_root}" ]] || die "snapshot root is invalid"
[[ -d "${staging_root}" && ! -L "${staging_root}" ]] || die "staging root is invalid"
validate_owned_directory "${snapshots_root}" "snapshot root"
validate_owned_directory "${staging_root}" "staging root"
mkdir "${operation_lock}" 2>/dev/null || die "another Amiary backup/restore operation is active"

snapshot_id=$(date -u '+%Y%m%dT%H%M%SZ')
created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
snapshot=$(snapshot_directory "${snapshot_id}")
staging_parent="${staging_root}/run.$$.${snapshot_id}"
staging="${staging_parent}/${snapshot_id}"

cleanup() {
  if [[ -n "${staging_parent:-}" && "${staging_parent}" == "${staging_root}/run."* && -d "${staging_parent}" && ! -L "${staging_parent}" ]]; then
    rm -rf -- "${staging_parent}"
  fi
  rmdir "${operation_lock}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[[ ! -e "${snapshot}" ]] || die "snapshot identifier already exists"
mkdir -p "${staging}/objects"
validate_owned_directory "${staging}" "snapshot staging directory"

# Capture a stable current-state snapshot. Object inventory is taken before and
# after each quiet mirror; a concurrent write causes a complete retry. The mc
# container receives the two-line credential as a read-only file, never through
# arguments, environment values, or output.
set +e
docker run --rm \
  --network "${AMIARY_MINIO_NETWORK}" \
  --user "${container_uid}:${container_gid}" \
  --read-only \
  --tmpfs "/tmp:rw,nosuid,nodev,noexec,size=32m,mode=0700,uid=${container_uid},gid=${container_gid}" \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --volume "${AMIARY_MINIO_BACKUP_CREDENTIALS_FILE}:/run/secrets/amiary-backup.credentials:ro" \
  --volume "${staging}:/snapshot" \
  --env MINIO_HOST="${AMIARY_MINIO_HOST}" \
  --env BUCKET="${AMIARY_MINIO_BUCKET}" \
  --entrypoint /bin/sh \
  "${AMIARY_MC_IMAGE}" -eu -c '
    access_key=$(head -n 1 /run/secrets/amiary-backup.credentials)
    secret_key=$(tail -n 1 /run/secrets/amiary-backup.credentials)
    export MC_CONFIG_DIR=/tmp/mc
    mc alias set source "${MINIO_HOST}" "${access_key}" "${secret_key}" >/dev/null 2>&1
    mc stat "source/${BUCKET}" >/dev/null 2>&1

    attempt=1
    while [ "${attempt}" -le 3 ]; do
      rm -rf /snapshot/attempt
      mkdir -p /snapshot/attempt/objects
      mc ls --recursive --json "source/${BUCKET}" > /snapshot/attempt/before.jsonl 2>/dev/null
      mc mirror --quiet --overwrite --retry "source/${BUCKET}/" /snapshot/attempt/objects/ >/dev/null 2>&1
      mc ls --recursive --json "source/${BUCKET}" > /snapshot/attempt/after.jsonl 2>/dev/null
      before=$(sha256sum < /snapshot/attempt/before.jsonl)
      after=$(sha256sum < /snapshot/attempt/after.jsonl)
      if [ "${before%% *}" = "${after%% *}" ]; then
        rm -rf /snapshot/objects
        mv /snapshot/attempt/objects /snapshot/objects
        mv /snapshot/attempt/before.jsonl /snapshot/source-inventory.jsonl
        rm -rf /snapshot/attempt
        exit 0
      fi
      attempt=$((attempt + 1))
    done
    exit 42
  ' >/dev/null 2>&1
copy_status=$?
set -e

if [[ "${copy_status}" == 42 ]]; then
  die "Amiary bucket changed throughout all snapshot attempts; no backup was published"
fi
[[ "${copy_status}" == 0 ]] || die "Amiary encrypted-object snapshot container failed with status ${copy_status}"
[[ -f "${staging}/source-inventory.jsonl" ]] || die "snapshot inventory was not produced"

write_snapshot_manifests "${staging}" "${snapshot_id}" "${created_at}"
verify_snapshot "${staging}"
mv "${staging}" "${snapshot}"
rmdir "${staging_parent}"
staging_parent=
rmdir "${operation_lock}"
trap - EXIT

info "published verified Amiary snapshot ${snapshot_id}"
"${script_dir}/prune-amiary-backups.sh" --apply
