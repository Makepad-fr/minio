#!/usr/bin/env bash
set -euo pipefail

remote_dir=${1:?remote directory is required}
staging_dir=${2:?staging directory is required}
password_file=${3:?BetaCrew password file is required}

[[ "${remote_dir}" == /srv/makepad/minio ]] || { echo "Unexpected remote directory: ${remote_dir}" >&2; exit 1; }
[[ "${staging_dir}" == /tmp/makepad-minio-* ]] || { echo "Unexpected staging directory: ${staging_dir}" >&2; exit 1; }
[[ "${password_file}" == /tmp/betacrew-minio-password ]] || { echo "Unexpected password path: ${password_file}" >&2; exit 1; }
[[ -d "${staging_dir}" ]] || { echo "Staging directory is missing." >&2; exit 1; }
[[ -s "${password_file}" ]] || { echo "BetaCrew password file is missing or empty." >&2; exit 1; }

docker run --rm \
  -v "${staging_dir}:/source:ro" \
  -v "${remote_dir}:/target" \
  -v /etc/makepad/minio:/protected \
  -v /etc/systemd/system:/systemd \
  -v "${password_file}:/incoming:ro" \
  alpine:3.22 sh -euc '
    install -d -m 0755 /target /target/envs/production /target/scripts /target/systemd
    install -o root -g root -m 0644 /source/compose.yml /target/compose.yml
    install -o root -g root -m 0644 /source/envs/production/.env.minio /target/envs/production/.env.minio
    install -o root -g root -m 0755 /source/scripts/provision-catwlk.sh /target/scripts/provision-catwlk.sh
    install -o root -g root -m 0755 /source/scripts/provision-betacrew.sh /target/scripts/provision-betacrew.sh
    install -o root -g root -m 0755 /source/scripts/backup-minio.sh /target/scripts/backup-minio.sh
    install -o root -g root -m 0755 /source/scripts/verify-betacrew-restore.sh /target/scripts/verify-betacrew-restore.sh
    install -o root -g root -m 0644 /source/systemd/makepad-minio.service /target/systemd/makepad-minio.service
    install -o root -g root -m 0644 /source/systemd/makepad-minio-backup.service /target/systemd/makepad-minio-backup.service
    install -o root -g root -m 0644 /source/systemd/makepad-minio-backup.timer /target/systemd/makepad-minio-backup.timer
    install -o root -g root -m 0644 /source/systemd/makepad-minio.service /systemd/makepad-minio.service
    install -o root -g root -m 0644 /source/systemd/makepad-minio-backup.service /systemd/makepad-minio-backup.service
    install -o root -g root -m 0644 /source/systemd/makepad-minio-backup.timer /systemd/makepad-minio-backup.timer

    temporary=$(mktemp /protected/minio.env.XXXXXX)
    trap '\''find "${temporary}" -delete 2>/dev/null || true'\'' EXIT
    grep -v "^MAKEPAD_BETACREW_PRODUCTION_PASSWORD=" /protected/minio.env > "${temporary}"
    password=$(tr -d "\r\n" < /incoming)
    [ -n "${password}" ]
    printf "MAKEPAD_BETACREW_PRODUCTION_PASSWORD=%s\n" "${password}" >> "${temporary}"
    chown root:root "${temporary}"
    chmod 0600 "${temporary}"
    mv "${temporary}" /protected/minio.env
  '

host_systemctl() {
  docker run --rm --privileged --pid=host alpine:3.22 \
    nsenter -t 1 -m -u -i -n -- systemctl "$@"
}

host_systemctl daemon-reload
host_systemctl enable --now makepad-minio.service
host_systemctl enable --now makepad-minio-backup.timer
docker run --rm --privileged --pid=host alpine:3.22 \
  nsenter -t 1 -m -u -i -n -- \
  systemd-run --quiet --wait --pipe --collect --unit=makepad-minio-betacrew-provision \
  /srv/makepad/minio/scripts/provision-betacrew.sh

find "${password_file}" -delete
find "${staging_dir}" -mindepth 1 -delete
rmdir "${staging_dir}"
