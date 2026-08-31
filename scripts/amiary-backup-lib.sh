#!/usr/bin/env bash

# Shared validation and manifest helpers for Amiary MinIO backup operations.
# This file is sourced by entrypoint scripts and must not print credentials,
# object names, checksum records, or object content.

set -Eeuo pipefail
export LC_ALL=C

readonly AMIARY_MC_IMAGE='minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727'
readonly AMIARY_PRODUCTION_BUCKET='amiary-photos'
readonly AMIARY_SNAPSHOT_SCHEMA='io.makepad.amiary.minio.snapshot/v1'

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

is_true() {
  [[ "${1,,}" == true ]]
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_var() {
  local name=$1
  [[ -n "${!name:-}" ]] || die "required variable is empty: ${name}"
}

stat_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

file_size() {
  if stat -c '%s' "$1" >/dev/null 2>&1; then
    stat -c '%s' "$1"
  else
    stat -f '%z' "$1"
  fi
}

sha256_file() {
  local output
  output=$(sha256sum < "$1")
  printf '%s' "${output%% *}"
}

canonical_directory() {
  local directory=$1
  (
    cd "${directory}"
    pwd -P
  )
}

validate_bucket_scope() {
  require_var AMIARY_MINIO_BUCKET
  if is_true "${AMIARY_BACKUP_TEST_MODE:-false}"; then
    [[ "${AMIARY_MINIO_BUCKET}" =~ ^amiary-backup-test-[a-z0-9-]+$ ]] \
      || die "test mode requires an isolated amiary-backup-test-* bucket"
    return
  fi
  [[ "${AMIARY_MINIO_BUCKET}" == "${AMIARY_PRODUCTION_BUCKET}" ]] \
    || die "backup tooling is restricted to the Amiary production bucket"
}

validate_credentials_file() {
  local path=${1:-} label=${2:-MinIO}
  local mode permission_digits group_digit other_digit line_count first_length second_length
  [[ -n "${path}" ]] || die "${label} credential path is empty"
  [[ "${path}" == /* ]] || die "${label} credential path must be absolute"
  [[ -f "${path}" && ! -L "${path}" && -r "${path}" ]] || die "${label} credential file must be a readable regular non-symlink file"

  mode=$(stat_mode "${path}")
  permission_digits=${mode: -3}
  group_digit=${permission_digits:1:1}
  other_digit=${permission_digits:2:1}
  (( (8#${group_digit} & 4) == 0 && (8#${other_digit} & 4) == 0 )) \
    || die "${label} credential file must not be group- or other-readable"

  line_count=$(awk 'END { print NR }' "${path}")
  [[ "${line_count}" == 2 ]] || die "${label} credential file must contain exactly two lines"
  first_length=$(awk 'NR == 1 { sub(/\r$/, ""); print length; exit }' "${path}")
  second_length=$(awk 'NR == 2 { sub(/\r$/, ""); print length; exit }' "${path}")
  ((first_length > 0)) || die "${label} credential access key is empty"
  ((second_length >= 32)) || die "${label} credential secret key must contain at least 32 characters"
}

validate_minio_config() {
  require_command docker
  require_var AMIARY_MINIO_NETWORK
  require_var AMIARY_MINIO_HOST
  [[ "${AMIARY_MINIO_NETWORK}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid Docker network name"
  [[ "${AMIARY_MINIO_HOST}" =~ ^https?://[A-Za-z0-9._:-]+$ ]] || die "invalid MinIO endpoint"
  validate_bucket_scope
}

validate_backup_minio_config() {
  validate_minio_config
  require_var AMIARY_MINIO_BACKUP_CREDENTIALS_FILE
  validate_credentials_file "${AMIARY_MINIO_BACKUP_CREDENTIALS_FILE}" "backup"
}

validate_restore_minio_config() {
  validate_minio_config
  require_var AMIARY_MINIO_RESTORE_CREDENTIALS_FILE
  validate_credentials_file "${AMIARY_MINIO_RESTORE_CREDENTIALS_FILE}" "restore"
}

validate_storage_config() {
  local mount_path root_path canonical_mount canonical_root
  for command in find jq sha256sum stat; do
    require_command "${command}"
  done
  require_var AMIARY_STORAGEBOX_MOUNT
  require_var AMIARY_BACKUP_ROOT
  mount_path=${AMIARY_STORAGEBOX_MOUNT}
  root_path=${AMIARY_BACKUP_ROOT}
  [[ "${mount_path}" == /* && "${mount_path}" != / ]] || die "Storage Box mount must be a narrow absolute path"
  [[ "${root_path}" == /* && "${root_path}" != / ]] || die "backup root must be a narrow absolute path"
  [[ -d "${mount_path}" && ! -L "${mount_path}" ]] || die "Storage Box mount is missing or is a symlink"

  if ! is_true "${AMIARY_BACKUP_TEST_MODE:-false}"; then
    [[ "${AMIARY_BACKUP_REQUIRE_MOUNTPOINT:-true}" == true ]] || die "production requires mountpoint enforcement"
    require_command mountpoint
    mountpoint --quiet "${mount_path}" || die "Storage Box path is not a mountpoint"
  elif is_true "${AMIARY_BACKUP_REQUIRE_MOUNTPOINT:-false}"; then
    require_command mountpoint
    mountpoint --quiet "${mount_path}" || die "test Storage Box path is not a mountpoint"
  fi

  [[ "${AMIARY_STORAGEBOX_TRANSPORT_ENCRYPTION_CONFIRMED:-}" == true ]] \
    || die "authenticated encrypted Storage Box transport must be confirmed"
  [[ "${AMIARY_STORAGEBOX_AT_REST_ENCRYPTION_CONFIRMED:-}" == true ]] \
    || die "Storage Box encryption at rest must be confirmed"

  umask 077
  mkdir -p "${root_path}"
  [[ -d "${root_path}" && ! -L "${root_path}" ]] || die "backup root is not a regular directory"
  canonical_mount=$(canonical_directory "${mount_path}")
  canonical_root=$(canonical_directory "${root_path}")
  [[ "${canonical_root}" == "${canonical_mount}/"* ]] || die "backup root must be below the Storage Box mount"
  AMIARY_STORAGEBOX_MOUNT=${canonical_mount}
  AMIARY_BACKUP_ROOT=${canonical_root}
  export AMIARY_STORAGEBOX_MOUNT AMIARY_BACKUP_ROOT
}

validate_retention_days() {
  AMIARY_BACKUP_RETENTION_DAYS=${AMIARY_BACKUP_RETENTION_DAYS:-35}
  [[ "${AMIARY_BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]] \
    || die "backup retention must be an integer number of days"
  ((AMIARY_BACKUP_RETENTION_DAYS >= 1 && AMIARY_BACKUP_RETENTION_DAYS <= 365)) \
    || die "backup retention must be between 1 and 365 days"
  export AMIARY_BACKUP_RETENTION_DAYS
}

validate_snapshot_id() {
  [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "invalid snapshot identifier"
}

snapshot_directory() {
  local snapshot_id=$1
  validate_snapshot_id "${snapshot_id}"
  printf '%s/snapshots/%s' "${AMIARY_BACKUP_ROOT}" "${snapshot_id}"
}

write_snapshot_manifests() {
  local snapshot=$1 snapshot_id=$2 created_at=$3
  local checksums="${snapshot}/SHA256SUMS.nul"
  local path relative digest size count=0 total_bytes=0 inventory_count manifest_hash checksums_hash inventory_hash

  [[ -d "${snapshot}/objects" && ! -L "${snapshot}/objects" ]] || die "snapshot object directory is invalid"
  [[ -z "$(find "${snapshot}/objects" -type l -print -quit)" ]] || die "snapshot contains an unexpected symlink"
  : > "${checksums}"
  while IFS= read -r -d '' path; do
    relative=${path#"${snapshot}/"}
    [[ "${relative}" != "${path}" ]] || die "snapshot path escaped its root"
    digest=$(sha256_file "${path}")
    size=$(file_size "${path}")
    printf '%s  %s\0' "${digest}" "${relative}" >> "${checksums}"
    count=$((count + 1))
    total_bytes=$((total_bytes + size))
  done < <(find "${snapshot}/objects" -type f -print0)

  inventory_count=$(wc -l < "${snapshot}/source-inventory.jsonl" | tr -d '[:space:]')
  [[ "${inventory_count}" == "${count}" ]] || die "source inventory and encrypted-object count differ"

  jq -n \
    --arg schema "${AMIARY_SNAPSHOT_SCHEMA}" \
    --arg bucket "${AMIARY_MINIO_BUCKET}" \
    --arg snapshotID "${snapshot_id}" \
    --arg createdAt "${created_at}" \
    --arg mcImage "${AMIARY_MC_IMAGE}" \
    --argjson objectCount "${count}" \
    --argjson totalBytes "${total_bytes}" \
    '{schema: $schema, bucket: $bucket, snapshotID: $snapshotID, createdAt: $createdAt, objectCount: $objectCount, totalBytes: $totalBytes, mcImage: $mcImage, content: "client-side-encrypted-objects"}' \
    > "${snapshot}/manifest.json"

  manifest_hash=$(sha256_file "${snapshot}/manifest.json")
  checksums_hash=$(sha256_file "${checksums}")
  inventory_hash=$(sha256_file "${snapshot}/source-inventory.jsonl")
  {
    printf '%s  manifest.json\n' "${manifest_hash}"
    printf '%s  SHA256SUMS.nul\n' "${checksums_hash}"
    printf '%s  source-inventory.jsonl\n' "${inventory_hash}"
  } > "${snapshot}/CONTROL.SHA256SUMS"
  : > "${snapshot}/COMPLETE"
}

verify_snapshot() {
  local snapshot=$1 snapshot_id expected_control actual_control
  local record digest separator relative object_path actual_digest record_count=0 record_bytes=0
  local actual_count=0 actual_bytes=0 path manifest_count manifest_bytes inventory_count

  [[ -d "${snapshot}" && ! -L "${snapshot}" ]] || die "snapshot directory is missing or invalid"
  snapshot_id=${snapshot##*/}
  validate_snapshot_id "${snapshot_id}"
  for required in manifest.json SHA256SUMS.nul source-inventory.jsonl CONTROL.SHA256SUMS COMPLETE; do
    [[ -f "${snapshot}/${required}" && ! -L "${snapshot}/${required}" ]] || die "snapshot control files are incomplete"
  done
  [[ -d "${snapshot}/objects" && ! -L "${snapshot}/objects" ]] || die "snapshot object directory is invalid"
  [[ -z "$(find "${snapshot}/objects" -type l -print -quit)" ]] || die "snapshot contains an unexpected symlink"

  expected_control=$(<"${snapshot}/CONTROL.SHA256SUMS")
  actual_control=$(printf '%s  manifest.json\n%s  SHA256SUMS.nul\n%s  source-inventory.jsonl' \
    "$(sha256_file "${snapshot}/manifest.json")" \
    "$(sha256_file "${snapshot}/SHA256SUMS.nul")" \
    "$(sha256_file "${snapshot}/source-inventory.jsonl")")
  [[ "${expected_control}" == "${actual_control}" ]] || die "snapshot control manifest verification failed"

  jq -e \
    --arg schema "${AMIARY_SNAPSHOT_SCHEMA}" \
    --arg bucket "${AMIARY_MINIO_BUCKET}" \
    --arg snapshotID "${snapshot_id}" \
    --arg mcImage "${AMIARY_MC_IMAGE}" \
    '.schema == $schema and .bucket == $bucket and .snapshotID == $snapshotID and .mcImage == $mcImage and .content == "client-side-encrypted-objects" and (.objectCount | type == "number") and (.totalBytes | type == "number")' \
    "${snapshot}/manifest.json" >/dev/null || die "snapshot metadata contract is invalid"
  manifest_count=$(jq -r '.objectCount' "${snapshot}/manifest.json")
  manifest_bytes=$(jq -r '.totalBytes' "${snapshot}/manifest.json")

  while IFS= read -r -d '' record; do
    ((${#record} >= 67)) || die "encrypted-object checksum manifest is malformed"
    digest=${record:0:64}
    separator=${record:64:2}
    relative=${record:66}
    [[ "${digest}" =~ ^[0-9a-f]{64}$ && "${separator}" == '  ' ]] || die "encrypted-object checksum manifest is malformed"
    [[ "${relative}" == objects/* && "${relative}" != objects/ && "${relative}" != /* ]] || die "checksum path escaped the encrypted-object directory"
    [[ "/${relative}/" != *'/../'* && "/${relative}/" != *'/./'* ]] || die "checksum path contains traversal components"
    object_path="${snapshot}/${relative}"
    [[ -f "${object_path}" && ! -L "${object_path}" ]] || die "encrypted object referenced by the manifest is missing"
    actual_digest=$(sha256_file "${object_path}")
    [[ "${actual_digest}" == "${digest}" ]] || die "encrypted-object checksum verification failed"
    record_count=$((record_count + 1))
    record_bytes=$((record_bytes + $(file_size "${object_path}")))
  done < "${snapshot}/SHA256SUMS.nul"

  while IFS= read -r -d '' path; do
    actual_count=$((actual_count + 1))
    actual_bytes=$((actual_bytes + $(file_size "${path}")))
  done < <(find "${snapshot}/objects" -type f -print0)
  inventory_count=$(wc -l < "${snapshot}/source-inventory.jsonl" | tr -d '[:space:]')
  [[ "${record_count}" == "${actual_count}" && "${record_count}" == "${inventory_count}" ]] \
    || die "snapshot object counts do not match"
  [[ "${record_count}" == "${manifest_count}" && "${record_bytes}" == "${manifest_bytes}" && "${actual_bytes}" == "${manifest_bytes}" ]] \
    || die "snapshot byte totals do not match"
}
