#!/usr/bin/env bash
set -Eeuo pipefail

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "${script_dir}/.." && pwd -P)
suffix=$$
network="amiary-backup-test-${suffix}"
container="amiary-backup-test-${suffix}"
bucket="amiary-backup-test-${suffix}"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/amiary-backup-test.XXXXXX")
app_credentials="${work_dir}/app.credentials"
backup_credentials="${work_dir}/backup.credentials"
restore_credentials="${work_dir}/restore.credentials"
source_files="${work_dir}/source"
restored_files="${work_dir}/restored"
storage_mount="${work_dir}/storagebox"
backup_root="${storage_mount}/amiary-minio"
restore_work="${work_dir}/restore-work"
mc_image='minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727'
test_uid=$(id -u)
test_gid=$(id -g)
test_phase=initialization

report_error() {
  local line=$1 status=$2
  trap - ERR
  printf 'Amiary MinIO disposable contract failed during %s at line %s (status %s).\n' \
    "${test_phase}" "${line}" "${status}" >&2
  return "${status}"
}
trap 'report_error "${LINENO}" "$?"' ERR

cleanup() {
  local status=$?
  trap - ERR EXIT
  docker rm -f "${container}" >/dev/null 2>&1 || true
  docker network rm "${network}" >/dev/null 2>&1 || true
  if [[ "${work_dir}" == "${TMPDIR:-/tmp}/amiary-backup-test."* && -d "${work_dir}" && ! -L "${work_dir}" ]]; then
    rm -rf -- "${work_dir}" || true
  fi
  exit "${status}"
}
trap cleanup EXIT

mkdir -p "${source_files}/profiles/a" "${source_files}/profiles/b" "${restored_files}" "${storage_mount}" "${restore_work}"
head -c 257 /dev/urandom > "${source_files}/profiles/a/photo.enc"
head -c 509 /dev/urandom > "${source_files}/profiles/b/photo.enc"
printf '%s\n%s\n' 'amiary-backup-test-app' 'test-only-app-secret-key-at-least-32-characters' > "${app_credentials}"
printf '%s\n%s\n' 'amiary-backup-test-reader' 'test-only-backup-secret-key-at-least-32-characters' > "${backup_credentials}"
printf '%s\n%s\n' 'amiary-backup-test-restore' 'test-only-restore-secret-key-at-least-32-characters' > "${restore_credentials}"
chmod 600 "${app_credentials}" "${backup_credentials}" "${restore_credentials}"
expected_a=$(sha256sum < "${source_files}/profiles/a/photo.enc")
expected_a=${expected_a%% *}
expected_b=$(sha256sum < "${source_files}/profiles/b/photo.enc")
expected_b=${expected_b%% *}

docker network create "${network}" >/dev/null
docker run -d --rm --name "${container}" --network "${network}" \
  --network-alias makepad-minio-amiary \
  -e MINIO_ROOT_USER=test-root-user \
  -e MINIO_ROOT_PASSWORD=test-root-password-at-least-32-chars \
  minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e \
  server /data >/dev/null

test_phase='identity provisioning'
provision_identity() {
  local purpose=$1 credentials=$2
  AMIARY_MINIO_NETWORK="${network}" \
  AMIARY_MINIO_HOST=http://makepad-minio-amiary:9000 \
  AMIARY_MINIO_BUCKET="${bucket}" \
  AMIARY_MINIO_POLICY_NAME="${bucket}-${purpose}" \
  AMIARY_MINIO_ADMIN_USER=test-root-user \
  AMIARY_MINIO_ADMIN_PASSWORD=test-root-password-at-least-32-chars \
  AMIARY_MINIO_CREDENTIALS_FILE="${credentials}" \
  AMIARY_MINIO_POLICY_TEMPLATE="${repo_root}/policies/amiary-${purpose}.json" \
    "${script_dir}/provision-amiary.sh" >/dev/null 2>&1
}
provision_identity app "${app_credentials}"
provision_identity backup "${backup_credentials}"
provision_identity restore "${restore_credentials}"

test_phase='initial app upload'
docker run --rm --network "${network}" \
  --user "${test_uid}:${test_gid}" \
  --read-only --tmpfs "/tmp:mode=0700,uid=${test_uid},gid=${test_gid}" \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --volume "${app_credentials}:/run/secrets/amiary-app.credentials:ro" \
  --volume "${source_files}:/payload:ro" \
  --env MINIO_HOST=http://makepad-minio-amiary:9000 --env BUCKET="${bucket}" \
  --entrypoint /bin/sh "${mc_image}" -eu -c '
    access_key=$(head -n 1 /run/secrets/amiary-app.credentials)
    secret_key=$(tail -n 1 /run/secrets/amiary-app.credentials)
    export MC_CONFIG_DIR=/tmp/mc
    mc alias set app "${MINIO_HOST}" "${access_key}" "${secret_key}" >/dev/null 2>&1
    mc cp --quiet --recursive /payload/ "app/${BUCKET}/" >/dev/null 2>&1
  ' >/dev/null 2>&1

# Scheduled backup credentials must be able to list/read the ciphertext but
# must fail closed for both writes and deletes.
test_phase='backup policy probe'
docker run --rm --network "${network}" \
  --user "${test_uid}:${test_gid}" \
  --read-only --tmpfs "/tmp:mode=0700,uid=${test_uid},gid=${test_gid}" \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --volume "${backup_credentials}:/run/secrets/amiary-backup.credentials:ro" \
  --volume "${source_files}:/payload:ro" \
  --env MINIO_HOST=http://makepad-minio-amiary:9000 --env BUCKET="${bucket}" \
  --entrypoint /bin/sh "${mc_image}" -eu -c '
    access_key=$(head -n 1 /run/secrets/amiary-backup.credentials)
    secret_key=$(tail -n 1 /run/secrets/amiary-backup.credentials)
    export MC_CONFIG_DIR=/tmp/mc
    mc alias set backup "${MINIO_HOST}" "${access_key}" "${secret_key}" >/dev/null 2>&1
    mc ls --recursive "backup/${BUCKET}" >/dev/null 2>&1
    mc cp --quiet "backup/${BUCKET}/profiles/a/photo.enc" /tmp/probe >/dev/null 2>&1
    if mc cp --quiet /payload/profiles/a/photo.enc "backup/${BUCKET}/forbidden.enc" >/dev/null 2>&1; then
      echo "backup identity unexpectedly wrote an object" >&2
      exit 1
    fi
    if mc rm --quiet --force "backup/${BUCKET}/profiles/a/photo.enc" >/dev/null 2>&1; then
      echo "backup identity unexpectedly deleted an object" >&2
      exit 1
    fi
  '

export AMIARY_BACKUP_TEST_MODE=true
export AMIARY_BACKUP_REQUIRE_MOUNTPOINT=false
export AMIARY_MINIO_NETWORK="${network}"
export AMIARY_MINIO_HOST=http://makepad-minio-amiary:9000
export AMIARY_MINIO_BUCKET="${bucket}"
export AMIARY_MINIO_BACKUP_CREDENTIALS_FILE="${backup_credentials}"
export AMIARY_MINIO_RESTORE_CREDENTIALS_FILE="${restore_credentials}"
export AMIARY_STORAGEBOX_MOUNT="${storage_mount}"
export AMIARY_BACKUP_ROOT="${backup_root}"
export AMIARY_STORAGEBOX_TRANSPORT_ENCRYPTION_CONFIRMED=true
export AMIARY_STORAGEBOX_AT_REST_ENCRYPTION_CONFIRMED=true
export AMIARY_BACKUP_RETENTION_DAYS=35
export AMIARY_RESTORE_WORK_DIR="${restore_work}"

test_phase='snapshot backup'
"${script_dir}/backup-amiary-bucket.sh" >/dev/null
snapshots=("${backup_root}"/snapshots/*)
test "${#snapshots[@]}" -eq 1
snapshot_id=${snapshots[0]##*/}
test_phase='snapshot verification'
"${script_dir}/verify-amiary-backup.sh" "${snapshot_id}" >/dev/null

# Change every aspect of the current set: overwrite one object, delete one,
# and add one. Restore must return exactly to the snapshot.
head -c 313 /dev/urandom > "${source_files}/profiles/a/photo.enc"
head -c 197 /dev/urandom > "${source_files}/extra.enc"
test_phase='source mutation'
docker run --rm --network "${network}" \
  --user "${test_uid}:${test_gid}" \
  --read-only --tmpfs "/tmp:mode=0700,uid=${test_uid},gid=${test_gid}" \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --volume "${app_credentials}:/run/secrets/amiary-app.credentials:ro" \
  --volume "${source_files}:/payload:ro" \
  --env MINIO_HOST=http://makepad-minio-amiary:9000 --env BUCKET="${bucket}" \
  --entrypoint /bin/sh "${mc_image}" -eu -c '
    access_key=$(head -n 1 /run/secrets/amiary-app.credentials)
    secret_key=$(tail -n 1 /run/secrets/amiary-app.credentials)
    export MC_CONFIG_DIR=/tmp/mc
    mc alias set app "${MINIO_HOST}" "${access_key}" "${secret_key}" >/dev/null 2>&1
    mc cp --quiet /payload/profiles/a/photo.enc "app/${BUCKET}/profiles/a/photo.enc" >/dev/null 2>&1
    mc rm --quiet --force "app/${BUCKET}/profiles/b/photo.enc" >/dev/null 2>&1
    mc cp --quiet /payload/extra.enc "app/${BUCKET}/extra.enc" >/dev/null 2>&1
  ' >/dev/null 2>&1

export AMIARY_RESTORE_CONFIRM_PRODUCTION_BUCKET="${bucket}"
export AMIARY_RESTORE_CONFIRM_REPLACE_CURRENT_OBJECTS=REPLACE_AMIARY_PRODUCTION_OBJECTS
export AMIARY_RESTORE_CONFIRM_WRITES_PAUSED=AMIARY_WRITES_ARE_PAUSED
test_phase='snapshot restore'
"${script_dir}/restore-amiary-bucket.sh" "${snapshot_id}" >/dev/null

test_phase='restored state download'
docker run --rm --network "${network}" \
  --user "${test_uid}:${test_gid}" \
  --read-only --tmpfs "/tmp:mode=0700,uid=${test_uid},gid=${test_gid}" \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --volume "${backup_credentials}:/run/secrets/amiary-backup.credentials:ro" \
  --volume "${restored_files}:/result" \
  --env MINIO_HOST=http://makepad-minio-amiary:9000 --env BUCKET="${bucket}" \
  --entrypoint /bin/sh "${mc_image}" -eu -c '
    access_key=$(head -n 1 /run/secrets/amiary-backup.credentials)
    secret_key=$(tail -n 1 /run/secrets/amiary-backup.credentials)
    export MC_CONFIG_DIR=/tmp/mc
    mc alias set app "${MINIO_HOST}" "${access_key}" "${secret_key}" >/dev/null 2>&1
    mc mirror --quiet "app/${BUCKET}/" /result/ >/dev/null 2>&1
  ' >/dev/null 2>&1

test_phase='restored state verification'
actual_a=$(sha256sum < "${restored_files}/profiles/a/photo.enc")
actual_a=${actual_a%% *}
actual_b=$(sha256sum < "${restored_files}/profiles/b/photo.enc")
actual_b=${actual_b%% *}
test "${actual_a}" = "${expected_a}"
test "${actual_b}" = "${expected_b}"
test ! -e "${restored_files}/extra.enc"

# Corruption must be detected without emitting the object path or content.
test_phase='corruption detection'
first_snapshot_object=$(find "${snapshots[0]}/objects" -type f -print -quit)
printf 'x' >> "${first_snapshot_object}"
if "${script_dir}/verify-amiary-backup.sh" "${snapshot_id}" >/dev/null 2>&1; then
  echo "corrupted snapshot passed manifest verification" >&2
  exit 1
fi

# Retention deletes only complete, timestamp-named snapshot directories.
test_phase='retention enforcement'
old_snapshot="${backup_root}/snapshots/20000101T000000Z"
mkdir -p "${old_snapshot}/objects"
for marker in manifest.json SHA256SUMS.nul source-inventory.jsonl CONTROL.SHA256SUMS COMPLETE; do
  : > "${old_snapshot}/${marker}"
done
"${script_dir}/prune-amiary-backups.sh" --apply >/dev/null
test ! -e "${old_snapshot}"

echo "Amiary MinIO disposable backup, verification, restore, and retention test passed."
