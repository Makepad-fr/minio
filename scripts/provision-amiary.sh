#!/usr/bin/env bash
set -euo pipefail
set +x
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/amiary-backup-lib.sh
source "${script_dir}/amiary-backup-lib.sh"

: "${AMIARY_MINIO_NETWORK:?AMIARY_MINIO_NETWORK is required}"
: "${AMIARY_MINIO_HOST:?AMIARY_MINIO_HOST is required}"
: "${AMIARY_MINIO_BUCKET:?AMIARY_MINIO_BUCKET is required}"
: "${AMIARY_MINIO_POLICY_NAME:?AMIARY_MINIO_POLICY_NAME is required}"
: "${AMIARY_MINIO_ADMIN_USER:?AMIARY_MINIO_ADMIN_USER is required}"
: "${AMIARY_MINIO_ADMIN_PASSWORD:?AMIARY_MINIO_ADMIN_PASSWORD is required}"
: "${AMIARY_MINIO_CREDENTIALS_FILE:?AMIARY_MINIO_CREDENTIALS_FILE is required}"
: "${AMIARY_MINIO_POLICY_TEMPLATE:?AMIARY_MINIO_POLICY_TEMPLATE is required}"

mc_image=${AMIARY_MC_IMAGE:-ghcr.io/makepad-fr/visitaki-test-minio@sha256:f6efb212cad3b62f78ca02339f16d8bc28d5bb2fbe792dfc21225c6037d2af8b}

[[ "${AMIARY_MINIO_BUCKET}" =~ ^amiary-(photos(-canary|-test)?|backup-test-[a-z0-9-]+)$ ]] \
  || { echo "Invalid Amiary bucket name." >&2; exit 1; }
[[ "${AMIARY_MINIO_POLICY_NAME}" =~ ^[a-z0-9-]{3,64}$ ]] \
  || { echo "Invalid Amiary policy name." >&2; exit 1; }
validate_credentials_file "${AMIARY_MINIO_CREDENTIALS_FILE}" "provisioning"
test -r "${AMIARY_MINIO_POLICY_TEMPLATE}" || { echo "Policy template is not readable." >&2; exit 1; }

mapfile -t credential_lines < "${AMIARY_MINIO_CREDENTIALS_FILE}"
if ((${#credential_lines[@]} != 2)); then
  echo "Credentials file must contain exactly two lines." >&2
  exit 1
fi
identity_access_key=${credential_lines[0]}
identity_secret_key=${credential_lines[1]}
[[ "${identity_access_key}" =~ ^amiary-[a-z0-9-]+$ ]] || { echo "Amiary identity must have a dedicated amiary- prefix." >&2; exit 1; }
if ((${#identity_secret_key} < 32)); then
  echo "Amiary secret key must contain at least 32 characters." >&2
  exit 1
fi

policy_file=$(mktemp "${TMPDIR:-/tmp}/amiary-minio-policy.XXXXXX")
cleanup() {
  rm -f "${policy_file}"
}
trap cleanup EXIT
sed "s/AMIARY_BUCKET/${AMIARY_MINIO_BUCKET}/g" "${AMIARY_MINIO_POLICY_TEMPLATE}" > "${policy_file}"
# The pinned mc image runs unprivileged. Docker Desktop transparently maps the
# bind mount, while native Linux preserves the host UID and mktemp's 0600 mode.
# The rendered policy contains no credentials, so make only this temporary
# policy world-readable for the duration of the read-only container mount.
chmod 0444 "${policy_file}"

# Docker inherits these values; credentials are not embedded in host argv.
export ADMIN_USER="$AMIARY_MINIO_ADMIN_USER" ADMIN_PASSWORD="$AMIARY_MINIO_ADMIN_PASSWORD"
export IDENTITY_ACCESS_KEY="$identity_access_key" IDENTITY_SECRET_KEY="$identity_secret_key"
for attempt in $(seq 1 30); do
  if docker run --rm --network "${AMIARY_MINIO_NETWORK}" \
    --read-only --tmpfs /tmp:mode=0700 --tmpfs /root/.mc:mode=0700 \
    --cap-drop ALL --security-opt no-new-privileges:true \
    -e ADMIN_USER \
    -e ADMIN_PASSWORD \
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
  -e ADMIN_USER \
  -e ADMIN_PASSWORD \
  -e IDENTITY_ACCESS_KEY \
  -e IDENTITY_SECRET_KEY \
  -e MINIO_HOST="${AMIARY_MINIO_HOST}" \
  -e BUCKET="${AMIARY_MINIO_BUCKET}" \
  -e POLICY_NAME="${AMIARY_MINIO_POLICY_NAME}" \
  --entrypoint /bin/sh "${mc_image}" -eu -c '
    mc alias set local "${MINIO_HOST}" "${ADMIN_USER}" "${ADMIN_PASSWORD}" >/dev/null
    users=$(mc admin user list --json local)
    case "${users}" in
      *\"accessKey\":\"${IDENTITY_ACCESS_KEY}\"*)
        user_info=$(mc admin user info local "${IDENTITY_ACCESS_KEY}" --json)
        case "${user_info}" in
          *\"policyName\":\"${POLICY_NAME}\"*) ;;
          *) echo "Existing Amiary identity has unexpected policy scope." >&2; exit 1 ;;
        esac
        case "${user_info}" in
          *\"memberOf\":*) echo "Existing Amiary identity has group membership." >&2; exit 1 ;;
        esac
        mc alias set retained "${MINIO_HOST}" "${IDENTITY_ACCESS_KEY}" "${IDENTITY_SECRET_KEY}" >/dev/null
        mc ls "retained/${BUCKET}" >/dev/null
        ;;
      *) mc admin user add local "${IDENTITY_ACCESS_KEY}" "${IDENTITY_SECRET_KEY}" >/dev/null ;;
    esac
    mc mb --ignore-existing "local/${BUCKET}" >/dev/null
    mc anonymous set none "local/${BUCKET}" >/dev/null
    mc version enable "local/${BUCKET}" >/dev/null
    mc admin policy create local "${POLICY_NAME}" /policy.json >/dev/null
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
  -e IDENTITY_ACCESS_KEY \
  -e IDENTITY_SECRET_KEY \
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
