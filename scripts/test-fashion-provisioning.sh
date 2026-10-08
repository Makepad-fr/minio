#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
container="fashion-storage-review-$$"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT
image=ghcr.io/makepad-fr/visitaki-test-minio@sha256:f6efb212cad3b62f78ca02339f16d8bc28d5bb2fbe792dfc21225c6037d2af8b
docker run -d --network none --name "$container" --memory 1g --tmpfs /data:size=268435456 -e MINIO_ROOT_USER=fixture-admin -e MINIO_ROOT_PASSWORD=disposable-admin-password "$image" server /data >/dev/null
for _ in {1..30}; do
 if docker exec "$container" mc alias set admin http://127.0.0.1:9000 fixture-admin disposable-admin-password >/dev/null 2>&1; then break; fi
 sleep 1
done
export MINIO_CONTAINER_NAME="$container" MINIO_ICEBERG_ACCESS_KEY=scraping-iceberg MINIO_ICEBERG_SECRET_KEY=disposable-fashion-password-at-least-32-characters
for _ in 1 2; do bash "$root/scripts/provision-fashion-iceberg.sh"; done
docker exec "$container" mc alias set app http://127.0.0.1:9000 scraping-iceberg "$MINIO_ICEBERG_SECRET_KEY" >/dev/null
printf private-fashion | docker exec -i "$container" mc pipe app/fashion-iceberg/probe >/dev/null
[[ $(docker exec "$container" mc cat app/fashion-iceberg/probe) == private-fashion ]]
docker exec "$container" mc mb admin/unrelated >/dev/null
for operation in 'ls app/unrelated' 'admin user list app'; do
 if docker exec "$container" sh -c "mc $operation" >/dev/null 2>&1; then echo 'Fashion escaped its scope' >&2; exit 1; fi
done
docker exec "$container" mc anonymous get admin/fashion-iceberg | grep -q private
if MINIO_ICEBERG_SECRET_KEY=wrong-password-must-never-replace-existing bash "$root/scripts/provision-fashion-iceberg.sh" >/dev/null 2>&1; then echo 'Replaced existing password' >&2; exit 1; fi
[[ $(docker exec "$container" mc cat app/fashion-iceberg/probe) == private-fashion ]]
if MINIO_ICEBERG_ACCESS_KEY=unrelated bash "$root/scripts/provision-fashion-iceberg.sh" >/dev/null 2>&1; then exit 1; fi
docker exec "$container" mc admin policy attach admin readwrite --user scraping-iceberg >/dev/null
if bash "$root/scripts/provision-fashion-iceberg.sh" >/dev/null 2>&1; then echo 'Accepted unexpected existing policy scope' >&2; exit 1; fi
printf '%s\n' 'PASS: repeated provisioning, private read/write, cross-bucket/admin denial and credential retention.'
