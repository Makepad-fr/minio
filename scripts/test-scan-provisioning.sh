#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
container="makepad-scan-minio-test-${GITHUB_RUN_ID:-local}-$$"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT
image=quay.io/minio/minio@sha256:d249d1fb6966de4d8ad26c04754b545205ff15a62e4fd19ebd0f26fa5baacbc0
docker run -d --name "$container" --memory 1g --cpus 2 --tmpfs /data:size=268435456 -e MINIO_ROOT_USER=scan-test-root -e MINIO_ROOT_PASSWORD=scan-disposable-root-password -v "$root/scripts:/source/scripts:ro" -v "$root/policies:/source/policies:ro" "$image" server /data >/dev/null
for i in {1..30}; do
  if docker exec "$container" mc alias set ci-admin http://127.0.0.1:9000 scan-test-root scan-disposable-root-password >/dev/null 2>&1; then break; fi
  sleep 1
done
for i in 1 2; do
  docker exec -e SCAN_STORAGE_PASSWORD=disposable-scanner-password-at-least-32-characters "$container" bash /source/scripts/provision-makepad-scan.sh
done
docker exec "$container" mc alias set ci-app http://127.0.0.1:9000 makepad-scan-app disposable-scanner-password-at-least-32-characters >/dev/null
printf scanner-test | docker exec -i "$container" mc pipe ci-app/makepad-scan/probe.txt >/dev/null
[[ $(docker exec "$container" mc cat ci-app/makepad-scan/probe.txt) == scanner-test ]]
docker exec "$container" mc mb ci-admin/unrelated-test >/dev/null
if docker exec "$container" mc ls ci-app/unrelated-test >/dev/null 2>&1; then echo 'Application escaped bucket scope' >&2; exit 1; fi
docker exec "$container" mc anonymous get ci-admin/makepad-scan | grep -q private
if docker exec -e SCAN_STORAGE_PASSWORD=wrong-password-must-never-replace-existing "$container" bash /source/scripts/provision-makepad-scan.sh >/dev/null 2>&1; then echo 'Unexpected credential replacement' >&2; exit 1; fi
[[ $(docker exec "$container" mc cat ci-app/makepad-scan/probe.txt) == scanner-test ]]
echo 'PASS: repeatable provisioning, private bucket, scoped read/write, existing password retained.'
