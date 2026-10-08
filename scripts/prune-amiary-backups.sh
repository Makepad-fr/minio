#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/amiary-backup-lib.sh
source "${script_dir}/amiary-backup-lib.sh"

apply=false
case "${1:-}" in
  '') ;;
  --apply) apply=true ;;
  *) die "usage: scripts/prune-amiary-backups.sh [--apply]" ;;
esac
[[ $# -le 1 ]] || die "usage: scripts/prune-amiary-backups.sh [--apply]"

validate_bucket_scope
validate_storage_config
validate_retention_days
snapshots_root="${AMIARY_BACKUP_ROOT}/snapshots"
operation_lock="${AMIARY_BACKUP_ROOT}/.operation.lock"
mkdir -p "${snapshots_root}"
[[ -d "${snapshots_root}" && ! -L "${snapshots_root}" ]] || die "snapshot root is invalid"
mkdir "${operation_lock}" 2>/dev/null || die "another Amiary backup/restore operation is active"
trap 'rmdir "${operation_lock}" >/dev/null 2>&1 || true' EXIT

if cutoff=$(date -u -d "${AMIARY_BACKUP_RETENTION_DAYS} days ago" '+%Y%m%dT%H%M%SZ' 2>/dev/null); then
  :
else
  cutoff=$(date -u -v-"${AMIARY_BACKUP_RETENTION_DAYS}"d '+%Y%m%dT%H%M%SZ')
fi
validate_snapshot_id "${cutoff}"

candidate_count=0
deleted_count=0
while IFS= read -r -d '' candidate; do
  [[ -d "${candidate}" && ! -L "${candidate}" ]] || continue
  snapshot_id=${candidate##*/}
  [[ "${snapshot_id}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
  [[ "${snapshot_id}" < "${cutoff}" ]] || continue
  [[ "${candidate}" == "${snapshots_root}/${snapshot_id}" ]] || die "retention candidate escaped snapshot root"
  for marker in manifest.json SHA256SUMS.nul source-inventory.jsonl CONTROL.SHA256SUMS COMPLETE; do
    [[ -f "${candidate}/${marker}" && ! -L "${candidate}/${marker}" ]] \
      || die "old snapshot is incomplete; inspect it manually instead of pruning"
  done
  [[ -d "${candidate}/objects" && ! -L "${candidate}/objects" ]] \
    || die "old snapshot object directory is invalid"
  candidate_count=$((candidate_count + 1))
  if is_true "${apply}"; then
    rm -rf -- "${candidate}"
    deleted_count=$((deleted_count + 1))
  fi
done < <(find "${snapshots_root}" -mindepth 1 -maxdepth 1 -type d -print0)

if is_true "${apply}"; then
  info "pruned ${deleted_count} Amiary snapshots older than ${AMIARY_BACKUP_RETENTION_DAYS} days"
else
  info "dry run: ${candidate_count} Amiary snapshots are older than ${AMIARY_BACKUP_RETENTION_DAYS} days"
fi
