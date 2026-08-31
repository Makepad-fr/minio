#!/usr/bin/env bash
set -euo pipefail

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
suffix=$$
network="amiary-minio-test-${suffix}"
container="amiary-minio-test-${suffix}"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/amiary-minio-test.XXXXXX")
mc_image='minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727'

cleanup() {
  docker rm -f "${container}" >/dev/null 2>&1 || true
  docker network rm "${network}" >/dev/null 2>&1 || true
  rm -f "${work_dir}"/*.credentials
  rmdir "${work_dir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '%s\n%s\n' 'amiary-test-app' 'test-only-app-secret-key-at-least-32-characters' > "${work_dir}/app.credentials"
printf '%s\n%s\n' 'amiary-test-backup' 'test-only-backup-secret-key-at-least-32-characters' > "${work_dir}/backup.credentials"
printf '%s\n%s\n' 'amiary-test-restore' 'test-only-restore-secret-key-at-least-32-characters' > "${work_dir}/restore.credentials"
chmod 600 "${work_dir}"/*.credentials

docker network create "${network}" >/dev/null
docker run -d --rm --name "${container}" --network "${network}" \
  --network-alias makepad-minio-amiary \
  -e MINIO_ROOT_USER=test-root-user \
  -e MINIO_ROOT_PASSWORD=test-root-password-at-least-32-chars \
  minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e \
  server /data >/dev/null

run_provisioning() {
  local purpose=$1
  AMIARY_MINIO_NETWORK="${network}" \
  AMIARY_MINIO_HOST=http://makepad-minio-amiary:9000 \
  AMIARY_MINIO_BUCKET=amiary-photos-test \
  AMIARY_MINIO_POLICY_NAME="amiary-test-${purpose}" \
  AMIARY_MINIO_ADMIN_USER=test-root-user \
  AMIARY_MINIO_ADMIN_PASSWORD=test-root-password-at-least-32-chars \
  AMIARY_MINIO_CREDENTIALS_FILE="${work_dir}/${purpose}.credentials" \
  AMIARY_MINIO_POLICY_TEMPLATE="${repo_root}/policies/amiary-${purpose}.json" \
    "${repo_root}/scripts/provision-amiary.sh"
}

run_provisioning app
run_provisioning backup
run_provisioning restore

# Prove the backup identity can enumerate and download encrypted objects, but
# cannot create, replace, or delete them. Restore remains a separate explicit
# identity with the exact write/delete permissions needed for a mirror restore.
docker run --rm --network "${network}" \
  --read-only --tmpfs /tmp:mode=0700 --tmpfs /root/.mc:mode=0700 \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -v "${work_dir}/app.credentials:/run/secrets/app.credentials:ro" \
  -v "${work_dir}/backup.credentials:/run/secrets/backup.credentials:ro" \
  -v "${work_dir}/restore.credentials:/run/secrets/restore.credentials:ro" \
  -e MINIO_HOST=http://makepad-minio-amiary:9000 \
  --entrypoint /bin/sh "${mc_image}" -eu -c '
    alias_from_file() {
      alias_name=$1
      credentials=$2
      access_key=$(head -n 1 "${credentials}")
      secret_key=$(tail -n 1 "${credentials}")
      mc alias set "${alias_name}" "${MINIO_HOST}" "${access_key}" "${secret_key}" >/dev/null 2>&1
    }
    export MC_CONFIG_DIR=/tmp/mc
    alias_from_file app /run/secrets/app.credentials
    alias_from_file backup /run/secrets/backup.credentials
    alias_from_file restore /run/secrets/restore.credentials
    printf test > /tmp/probe
    mc cp --quiet /tmp/probe app/amiary-photos-test/probe >/dev/null 2>&1
    mc ls backup/amiary-photos-test >/dev/null 2>&1
    mc cp --quiet backup/amiary-photos-test/probe /tmp/download >/dev/null 2>&1
    if mc cp --quiet /tmp/probe backup/amiary-photos-test/forbidden >/dev/null 2>&1; then
      echo "backup identity unexpectedly wrote an object" >&2
      exit 1
    fi
    if mc rm --quiet --force backup/amiary-photos-test/probe >/dev/null 2>&1; then
      echo "backup identity unexpectedly deleted an object" >&2
      exit 1
    fi
    mc cp --quiet /tmp/probe restore/amiary-photos-test/restored >/dev/null 2>&1
    mc rm --quiet --force restore/amiary-photos-test/restored >/dev/null 2>&1
  '

# Inject both direct-policy and group-membership drift into the backup identity.
# Reprovisioning must recreate it and converge to only the read-only policy.
docker run --rm --network "${network}" \
  --read-only --tmpfs /tmp:mode=0700 --tmpfs /root/.mc:mode=0700 \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -e ADMIN_USER=test-root-user \
  -e ADMIN_PASSWORD=test-root-password-at-least-32-chars \
  -e MINIO_HOST=http://makepad-minio-amiary:9000 \
  --entrypoint /bin/sh \
  "${mc_image}" -eu -c '
    mc alias set local "${MINIO_HOST}" "${ADMIN_USER}" "${ADMIN_PASSWORD}" >/dev/null
    mc admin policy attach local writeonly --user amiary-test-backup >/dev/null
    mc admin group add local amiary-unexpected-group amiary-test-backup >/dev/null
    mc admin policy attach local writeonly --group amiary-unexpected-group >/dev/null
  '
run_provisioning backup

for purpose in app backup restore; do
  user_info=$(docker run --rm --network "${network}" \
    --read-only --tmpfs /tmp:mode=0700 --tmpfs /root/.mc:mode=0700 \
    --cap-drop ALL --security-opt no-new-privileges:true \
    -e ADMIN_USER=test-root-user \
    -e ADMIN_PASSWORD=test-root-password-at-least-32-chars \
    -e MINIO_HOST=http://makepad-minio-amiary:9000 \
    -e ACCESS_KEY="amiary-test-${purpose}" \
    --entrypoint /bin/sh \
    "${mc_image}" -eu -c '
      mc alias set local "${MINIO_HOST}" "${ADMIN_USER}" "${ADMIN_PASSWORD}" >/dev/null
      mc admin user info local "${ACCESS_KEY}" --json
    ')
  [[ "${user_info}" == *"\"policyName\":\"amiary-test-${purpose}\""* ]]
  [[ "${user_info}" != *'"memberOf":'* ]]
done

echo "Amiary MinIO app, read-only backup, and manual-restore provisioning is repeatable."
