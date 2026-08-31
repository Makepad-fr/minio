#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
lib="${script_dir}/amiary-backup-lib.sh"
backup="${script_dir}/backup-amiary-bucket.sh"
restore="${script_dir}/restore-amiary-bucket.sh"
verify="${script_dir}/verify-amiary-backup.sh"
prune="${script_dir}/prune-amiary-backups.sh"
provision="${script_dir}/provision-amiary.sh"
env_example="${repo_root}/config/amiary-minio-backup.env.example"
service="${repo_root}/systemd/amiary-minio-backup.service"
timer="${repo_root}/systemd/amiary-minio-backup.timer"
workflow="${repo_root}/.github/workflows/amiary-contract.yml"
deploy_workflow="${repo_root}/.github/workflows/manual-deploy.yml"
backup_policy="${repo_root}/policies/amiary-backup.json"
restore_policy="${repo_root}/policies/amiary-restore.json"
readme="${repo_root}/README.md"

for file in "${lib}" "${backup}" "${restore}" "${verify}" "${prune}" "${provision}" \
  "${env_example}" "${service}" "${timer}" "${workflow}" "${deploy_workflow}" \
  "${backup_policy}" "${restore_policy}" "${readme}"; do
  test -s "${file}" || { echo "missing Amiary backup contract file: ${file}" >&2; exit 1; }
done

bash -n "${lib}" "${backup}" "${restore}" "${verify}" "${prune}" "${provision}"

digest='minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727'
grep -Fq "${digest}" "${lib}"
grep -Fq "AMIARY_PRODUCTION_BUCKET='amiary-photos'" "${lib}"
grep -Fq 'backup tooling is restricted to the Amiary production bucket' "${lib}"
# This validates the literal default expression.
# shellcheck disable=SC2016
grep -Fq 'AMIARY_BACKUP_RETENTION_DAYS=${AMIARY_BACKUP_RETENTION_DAYS:-35}' "${lib}"
grep -Fq 'client-side-encrypted-objects' "${lib}"
grep -Fq 'SHA256SUMS.nul' "${lib}"
grep -Fq 'CONTROL.SHA256SUMS' "${lib}"

grep -Fq '00,06,12,18:15:00 UTC' "${timer}"
grep -Fq 'Persistent=true' "${timer}"
grep -Fq 'ConditionPathIsMountPoint=/mnt/makepad-storagebox' "${service}"
grep -Fq 'NoNewPrivileges=true' "${service}"
grep -Fq 'AMIARY_BACKUP_RETENTION_DAYS=35' "${env_example}"
grep -Fq 'AMIARY_MINIO_BACKUP_CREDENTIALS_FILE=' "${env_example}"
grep -Fq 'AMIARY_MINIO_RESTORE_CREDENTIALS_FILE=' "${env_example}"
grep -Fq '/etc/makepad/secrets/minio/backup/amiary.credentials' "${service}"
if grep -Fq 'amiary-minio-restore.credentials' "${service}"; then
  echo "scheduled backup service must not be granted the manual restore credential" >&2
  exit 1
fi

jq -e '
  ([.Statement[].Action[]] | index("s3:GetObject") != null) and
  ([.Statement[].Action[]] | index("s3:ListBucket") != null) and
  ([.Statement[].Action[]] | index("s3:PutObject") == null) and
  ([.Statement[].Action[]] | index("s3:DeleteObject") == null) and
  ([.Statement[].Action[]] | index("s3:AbortMultipartUpload") == null)
' "${backup_policy}" >/dev/null
jq -e '
  ([.Statement[].Action[]] | index("s3:GetObject") != null) and
  ([.Statement[].Action[]] | index("s3:ListBucket") != null) and
  ([.Statement[].Action[]] | index("s3:PutObject") != null) and
  ([.Statement[].Action[]] | index("s3:DeleteObject") != null)
' "${restore_policy}" >/dev/null

for deploy_contract in \
  DEPLOY_AMIARY_BACKUP_ACCESS_KEY DEPLOY_AMIARY_BACKUP_SECRET_KEY \
  DEPLOY_AMIARY_RESTORE_ACCESS_KEY DEPLOY_AMIARY_RESTORE_SECRET_KEY \
  policies/amiary-backup.json policies/amiary-restore.json \
  'provision_amiary_identity backup' 'provision_amiary_identity restore'; do
  grep -Fq "${deploy_contract}" "${deploy_workflow}"
done

grep -Fq 'pull_request:' "${workflow}"
grep -Fq 'runs-on: ubuntu-24.04' "${workflow}"
grep -Fq 'actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09' "${workflow}"
grep -Fq 'timeout-minutes: 20' "${workflow}"
grep -Fq 'shellcheck scripts/*.sh' "${workflow}"
grep -Fq 'test-amiary-provisioning.sh' "${workflow}"
grep -Fq 'test-amiary-backup-disposable.sh' "${workflow}"
if grep -Eq '(docker[[:space:]]+stack[[:space:]]+deploy|(^|[[:space:]])ssh[[:space:]]|(^|[[:space:]])scp[[:space:]])' "${workflow}"; then
  echo "Amiary contract workflow must not deploy or access remote hosts" >&2
  exit 1
fi

grep -Fq 'AMIARY_RESTORE_CONFIRM_PRODUCTION_BUCKET' "${restore}"
grep -Fq 'REPLACE_AMIARY_PRODUCTION_OBJECTS' "${restore}"
grep -Fq 'AMIARY_WRITES_ARE_PAUSED' "${restore}"
grep -Fq -- '--remove' "${restore}"
# This validates the literal function call.
# shellcheck disable=SC2016
grep -Fq 'verify_snapshot "${verification_snapshot}"' "${restore}"

for hardened_script in "${backup}" "${restore}"; do
  grep -Fq -- '--read-only' "${hardened_script}"
  grep -Fq -- '--cap-drop ALL' "${hardened_script}"
  grep -Fq -- '--security-opt no-new-privileges:true' "${hardened_script}"
  if grep -Eq -- '--env[[:space:]]+[^=]*(ACCESS|SECRET|PASSWORD|CREDENTIAL)' "${hardened_script}"; then
    echo "credential material must not be passed through Docker environment arguments" >&2
    exit 1
  fi
  if grep -Eq '(^|[[:space:]])(cat|printf|echo)[[:space:]].*(credentials|secret_key|access_key)' "${hardened_script}"; then
    echo "backup tooling may expose credential material" >&2
    exit 1
  fi
done
# These validate the literal variable expansion in the entrypoint source.
# shellcheck disable=SC2016
grep -Fq '${AMIARY_MINIO_BACKUP_CREDENTIALS_FILE}:/run/secrets/amiary-backup.credentials:ro' "${backup}"
# shellcheck disable=SC2016
grep -Fq '${AMIARY_MINIO_RESTORE_CREDENTIALS_FILE}:/run/secrets/amiary-restore.credentials:ro' "${restore}"
if grep -Fq 'AMIARY_MINIO_RESTORE_CREDENTIALS_FILE' "${backup}"; then
  echo "scheduled backup script must not reference restore credentials" >&2
  exit 1
fi
if grep -Fq 'AMIARY_MINIO_BACKUP_CREDENTIALS_FILE' "${restore}"; then
  echo "manual restore script must not reuse backup credentials" >&2
  exit 1
fi

if grep -Eq '(set[[:space:]]+-x|--debug|--insecure)' "${lib}" "${backup}" "${restore}" "${verify}" "${prune}"; then
  echo "unsafe diagnostic or TLS option found in Amiary backup tooling" >&2
  exit 1
fi

grep -Fq 'six-hour RPO target' "${readme}"
grep -Fq 'RTO target is four hours' "${readme}"
grep -Fq '35 days' "${readme}"
grep -Fq 'never placed in' "${readme}"

echo "Amiary MinIO backup static contract is valid."
