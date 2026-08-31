#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/amiary-backup-lib.sh
source "${script_dir}/amiary-backup-lib.sh"

[[ $# -eq 1 ]] || die "usage: scripts/verify-amiary-backup.sh <snapshot-id>"
validate_bucket_scope
validate_storage_config
snapshot=$(snapshot_directory "$1")
verify_snapshot "${snapshot}"
info "verified Amiary snapshot $1"
