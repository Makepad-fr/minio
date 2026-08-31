#!/usr/bin/env bash
set -euo pipefail

: "${AMIARY_MINIO_NETWORK:?AMIARY_MINIO_NETWORK is required}"
: "${AMIARY_MINIO_HOST:?AMIARY_MINIO_HOST is required}"
: "${AMIARY_MINIO_BUCKET:?AMIARY_MINIO_BUCKET is required}"
: "${AMIARY_MINIO_POLICY_NAME:?AMIARY_MINIO_POLICY_NAME is required}"
: "${AMIARY_MINIO_ADMIN_USER:?AMIARY_MINIO_ADMIN_USER is required}"
: "${AMIARY_MINIO_ADMIN_PASSWORD:?AMIARY_MINIO_ADMIN_PASSWORD is required}"
: "${AMIARY_MINIO_CREDENTIALS_FILE:?AMIARY_MINIO_CREDENTIALS_FILE is required}"
: "${AMIARY_MINIO_POLICY_TEMPLATE:?AMIARY_MINIO_POLICY_TEMPLATE is required}"

mc_image=${AMIARY_MC_IMAGE:-minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727}

[[ "${AMIARY_MINIO_BUCKET}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] \
  || { echo "Invalid Amiary bucket name." >&2; exit 1; }
[[ "${AMIARY_MINIO_POLICY_NAME}" =~ ^[a-z0-9-]{3,64}$ ]] \
  || { echo "Invalid Amiary policy name." >&2; exit 1; }
test -r "${AMIARY_MINIO_CREDENTIALS_FILE}" || { echo "Credentials file is not readable." >&2; exit 1; }
test -r "${AMIARY_MINIO_POLICY_TEMPLATE}" || { echo "Policy template is not readable." >&2; exit 1; }

mapfile -t credential_lines < "${AMIARY_MINIO_CREDENTIALS_FILE}"
if ((${#credential_lines[@]} != 2)); then
  echo "Credentials file must contain exactly two lines." >&2
  exit 1
fi
identity_access_key=${credential_lines[0]}
identity_secret_key=${credential_lines[1]}
test -n "${identity_access_key}" || { echo "Amiary access key is empty." >&2; exit 1; }
if ((${#identity_secret_key} < 32)); then
  echo "Amiary secret key must contain at least 32 characters." >&2
  exit 1
fi

policy_file=$(mktemp "${TMPDIR:-/tmp}/amiary-minio-policy.XXXXXX.json")
cleanup() {
  rm -f "${policy_file}"
}
trap cleanup EXIT
sed "s/AMIARY_BUCKET/${AMIARY_MINIO_BUCKET}/g" "${AMIARY_MINIO_POLICY_TEMPLATE}" > "${policy_file}"

for attempt in $(seq 1 30); do
  if docker run --rm --network "${AMIARY_MINIO_NETWORK}" \
    --read-only --tmpfs /tmp:mode=0700 --tmpfs /root/.mc:mode=0700 \
    --cap-drop ALL --security-opt no-new-privileges:true \
    -e ADMIN_USER="${AMIARY_MINIO_ADMIN_USER}" \
    -e ADMIN_PASSWORD="${AMIARY_MINIO_ADMIN_PASSWORD}" \
    -e MINIO_HOST="${AMIARY_MINIO_HOST}" \
    --entrypoint /bin/sh "${mc_image}" -eu -c \
    'mc alias set local "${MINIO_HOST}" "${ADMIN_USER}" "${ADMIN_PASSWORD}" >/dev/null && mc ready local >/dev/null'; then
    break
  fi
  if ((attempt == 30)); then
    echo "Timed out waiting for Amiary MinIO endpoint." >&2
    exit 1
  fi
  sleep 2
done

docker run --rm --network "${AMIARY_MINIO_NETWORK}" \
  --read-only --tmpfs /tmp:mode=0700 --tmpfs /root/.mc:mode=0700 \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -v "${policy_file}:/policy.json:ro" \
  -e ADMIN_USER="${AMIARY_MINIO_ADMIN_USER}" \
  -e ADMIN_PASSWORD="${AMIARY_MINIO_ADMIN_PASSWORD}" \
  -e IDENTITY_ACCESS_KEY="${identity_access_key}" \
  -e IDENTITY_SECRET_KEY="${identity_secret_key}" \
  -e MINIO_HOST="${AMIARY_MINIO_HOST}" \
  -e BUCKET="${AMIARY_MINIO_BUCKET}" \
  -e POLICY_NAME="${AMIARY_MINIO_POLICY_NAME}" \
  --entrypoint /bin/sh "${mc_image}" -eu -c '
    mc alias set local "${MINIO_HOST}" "${ADMIN_USER}" "${ADMIN_PASSWORD}" >/dev/null
    mc mb --ignore-existing "local/${BUCKET}" >/dev/null
    mc version enable "local/${BUCKET}" >/dev/null
    mc admin policy create local "${POLICY_NAME}" /policy.json >/dev/null
    # The access key is dedicated to Amiary. Recreate it so any unexpected
    # direct policies or group memberships from prior drift are removed before
    # the single intended policy is attached.
    mc admin user remove local "${IDENTITY_ACCESS_KEY}" >/dev/null 2>&1 || true
    mc admin user add local "${IDENTITY_ACCESS_KEY}" "${IDENTITY_SECRET_KEY}" >/dev/null
    mc admin policy attach local "${POLICY_NAME}" --user "${IDENTITY_ACCESS_KEY}" >/dev/null
    user_info=$(mc admin user info local "${IDENTITY_ACCESS_KEY}" --json)
    case "${user_info}" in
      *\"policyName\":\"${POLICY_NAME}\"*) ;;
      *) echo "Amiary identity does not have the exact expected direct policy." >&2; exit 1 ;;
    esac
    case "${user_info}" in
      *\"memberOf\":*) echo "Amiary identity retained an unexpected group membership." >&2; exit 1 ;;
    esac
  '

docker run --rm --network "${AMIARY_MINIO_NETWORK}" \
  --read-only --tmpfs /tmp:mode=0700 --tmpfs /root/.mc:mode=0700 \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -e IDENTITY_ACCESS_KEY="${identity_access_key}" \
  -e IDENTITY_SECRET_KEY="${identity_secret_key}" \
  -e MINIO_HOST="${AMIARY_MINIO_HOST}" \
  -e BUCKET="${AMIARY_MINIO_BUCKET}" \
  --entrypoint /bin/sh "${mc_image}" -eu -c '
    mc alias set identity "${MINIO_HOST}" "${IDENTITY_ACCESS_KEY}" "${IDENTITY_SECRET_KEY}" >/dev/null
    mc stat "identity/${BUCKET}" >/dev/null
    if mc admin info identity >/dev/null 2>&1; then
      echo "Amiary credential unexpectedly has admin access." >&2
      exit 1
    fi
  '

echo "Amiary bucket, versioning, identity, and least-privilege policy are ready."
