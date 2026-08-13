#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
require_literal() { grep -Fq -- "$2" "${repo_root}/$1" || { echo "Missing BetaCrew MinIO contract in $1: $2" >&2; exit 1; }; }

require_literal envs/production/.env.minio "MAKEPAD_BETACREW_PRODUCTION_BUCKET=betacrew-production"
require_literal envs/production/.env.minio "MAKEPAD_BETACREW_PRODUCTION_USER=betacrew-production-app"
require_literal scripts/provision-betacrew.sh 'arn:aws:s3:::${MAKEPAD_BETACREW_PRODUCTION_BUCKET}/*'
require_literal scripts/provision-betacrew.sh "s3:DeleteObject"
require_literal scripts/backup-minio.sh 'betacrew-production'
require_literal systemd/makepad-minio.service "provision-betacrew.sh"
require_literal scripts/verify-betacrew-restore.sh "write-probe-backup-and-restore"
bash -n "${repo_root}/scripts/provision-betacrew.sh"
bash -n "${repo_root}/scripts/backup-minio.sh"
bash -n "${repo_root}/scripts/verify-betacrew-restore.sh"
echo "BetaCrew MinIO configuration is valid."
