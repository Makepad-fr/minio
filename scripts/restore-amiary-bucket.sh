#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/amiary-backup-lib.sh
source "${script_dir}/amiary-backup-lib.sh"

[[ $# -eq 1 ]] || die "usage: scripts/restore-amiary-bucket.sh <snapshot-id>"
snapshot_id=$1
validate_snapshot_id "${snapshot_id}"
validate_restore_minio_config
validate_storage_config

container_uid=$(stat_uid "${AMIARY_MINIO_RESTORE_CREDENTIALS_FILE}")
container_gid=$(stat_gid "${AMIARY_MINIO_RESTORE_CREDENTIALS_FILE}")

[[ "${AMIARY_RESTORE_CONFIRM_PRODUCTION_BUCKET:-}" == "${AMIARY_MINIO_BUCKET}" ]] \
  || die "set AMIARY_RESTORE_CONFIRM_PRODUCTION_BUCKET to the exact target bucket"
[[ "${AMIARY_RESTORE_CONFIRM_REPLACE_CURRENT_OBJECTS:-}" == REPLACE_AMIARY_PRODUCTION_OBJECTS ]] \
  || die "set AMIARY_RESTORE_CONFIRM_REPLACE_CURRENT_OBJECTS=REPLACE_AMIARY_PRODUCTION_OBJECTS"
[[ "${AMIARY_RESTORE_CONFIRM_WRITES_PAUSED:-}" == AMIARY_WRITES_ARE_PAUSED ]] \
  || die "set AMIARY_RESTORE_CONFIRM_WRITES_PAUSED=AMIARY_WRITES_ARE_PAUSED after stopping application writes"
require_var AMIARY_RESTORE_WORK_DIR
[[ "${AMIARY_RESTORE_WORK_DIR}" == /* && "${AMIARY_RESTORE_WORK_DIR}" != / ]] \
  || die "restore verification work directory must be a narrow absolute path"
umask 077
mkdir -p "${AMIARY_RESTORE_WORK_DIR}"
[[ -d "${AMIARY_RESTORE_WORK_DIR}" && ! -L "${AMIARY_RESTORE_WORK_DIR}" ]] \
  || die "restore verification work directory is invalid"
AMIARY_RESTORE_WORK_DIR=$(canonical_directory "${AMIARY_RESTORE_WORK_DIR}")
validate_owned_directory "${AMIARY_RESTORE_WORK_DIR}" "restore verification work directory"

snapshot=$(snapshot_directory "${snapshot_id}")
operation_lock="${AMIARY_BACKUP_ROOT}/.operation.lock"
mkdir "${operation_lock}" 2>/dev/null || die "another Amiary backup/restore operation is active"
verification_parent=$(mktemp -d "${AMIARY_RESTORE_WORK_DIR}/verify.${snapshot_id}.XXXXXX")
verification_snapshot="${verification_parent}/${snapshot_id}"

cleanup() {
  if [[ -n "${verification_parent:-}" && "${verification_parent}" == "${AMIARY_RESTORE_WORK_DIR}/verify.${snapshot_id}."* && -d "${verification_parent}" && ! -L "${verification_parent}" ]]; then
    rm -rf -- "${verification_parent}"
  fi
  rmdir "${operation_lock}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

verify_snapshot "${snapshot}"
mkdir -p "${verification_snapshot}/objects"
validate_owned_directory "${verification_snapshot}" "restore verification staging directory"

# Replace the current bucket view with the verified encrypted-object set. The
# source bucket is versioned, so deletes create versions, but this remains a
# destructive current-state operation and therefore requires all confirmations.
set +e
docker run --rm \
  --network "${AMIARY_MINIO_NETWORK}" \
  --user "${container_uid}:${container_gid}" \
  --read-only \
  --tmpfs "/tmp:rw,nosuid,nodev,noexec,size=32m,mode=0700,uid=${container_uid},gid=${container_gid}" \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --volume "${AMIARY_MINIO_RESTORE_CREDENTIALS_FILE}:/run/secrets/amiary-restore.credentials:ro" \
  --volume "${snapshot}:/snapshot:ro" \
  --env MINIO_HOST="${AMIARY_MINIO_HOST}" \
  --env BUCKET="${AMIARY_MINIO_BUCKET}" \
  --entrypoint /bin/sh \
  "${AMIARY_MC_IMAGE}" -eu -c '
    access_key=$(head -n 1 /run/secrets/amiary-restore.credentials)
    secret_key=$(tail -n 1 /run/secrets/amiary-restore.credentials)
    export MC_CONFIG_DIR=/tmp/mc
    mc alias set target "${MINIO_HOST}" "${access_key}" "${secret_key}" >/dev/null 2>&1
    mc stat "target/${BUCKET}" >/dev/null 2>&1
    mc mirror --quiet --overwrite --remove --retry /snapshot/objects/ "target/${BUCKET}/" >/dev/null 2>&1
  ' >/dev/null 2>&1
restore_status=$?
set -e
[[ "${restore_status}" == 0 ]] \
  || die "Amiary restore container failed with status ${restore_status}; keep writes paused and inspect the target before retrying"

# Download the resulting current state without printing names/content and check
# every encrypted object against the pre-restore snapshot manifest.
set +e
docker run --rm \
  --network "${AMIARY_MINIO_NETWORK}" \
  --user "${container_uid}:${container_gid}" \
  --read-only \
  --tmpfs "/tmp:rw,nosuid,nodev,noexec,size=32m,mode=0700,uid=${container_uid},gid=${container_gid}" \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --volume "${AMIARY_MINIO_RESTORE_CREDENTIALS_FILE}:/run/secrets/amiary-restore.credentials:ro" \
  --volume "${verification_snapshot}:/verification" \
  --env MINIO_HOST="${AMIARY_MINIO_HOST}" \
  --env BUCKET="${AMIARY_MINIO_BUCKET}" \
  --entrypoint /bin/sh \
  "${AMIARY_MC_IMAGE}" -eu -c '
    access_key=$(head -n 1 /run/secrets/amiary-restore.credentials)
    secret_key=$(tail -n 1 /run/secrets/amiary-restore.credentials)
    export MC_CONFIG_DIR=/tmp/mc
    mc alias set source "${MINIO_HOST}" "${access_key}" "${secret_key}" >/dev/null 2>&1

    attempt=1
    while [ "${attempt}" -le 3 ]; do
      rm -rf /verification/attempt
      mkdir -p /verification/attempt/objects
      mc ls --recursive --json "source/${BUCKET}" > /verification/attempt/before.jsonl 2>/dev/null
      mc mirror --quiet --overwrite --retry "source/${BUCKET}/" /verification/attempt/objects/ >/dev/null 2>&1
      mc ls --recursive --json "source/${BUCKET}" > /verification/attempt/after.jsonl 2>/dev/null
      before=$(sha256sum < /verification/attempt/before.jsonl)
      after=$(sha256sum < /verification/attempt/after.jsonl)
      if [ "${before%% *}" = "${after%% *}" ]; then
        rm -rf /verification/objects
        mv /verification/attempt/objects /verification/objects
        rm -rf /verification/attempt
        exit 0
      fi
      attempt=$((attempt + 1))
    done
    exit 42
  ' >/dev/null 2>&1
verification_download_status=$?
set -e
[[ "${verification_download_status}" == 0 ]] \
  || die "post-restore verification container failed with status ${verification_download_status}; keep writes paused"

for control_file in manifest.json SHA256SUMS.nul source-inventory.jsonl CONTROL.SHA256SUMS COMPLETE; do
  cp "${snapshot}/${control_file}" "${verification_snapshot}/${control_file}"
done
verify_snapshot "${verification_snapshot}"

info "restored and verified Amiary snapshot ${snapshot_id}"
