#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
name="visitaki-storage-test-$$"
trap 'docker rm -fv "$name" >/dev/null 2>&1 || true' EXIT
# No published ports, host volumes, or production credentials.
docker create --name "$name" --network none --cpus 0.5 --memory 384m \
 -e MINIO_ROOT_USER=integration-admin -e MINIO_ROOT_PASSWORD=disposable-storage-admin \
 quay.io/minio/minio@sha256:d249d1fb6966de4d8ad26c04754b545205ff15a62e4fd19ebd0f26fa5baacbc0 server /data >/dev/null
docker cp "$root/policies/visitaki-preview.json" "$name:/tmp/policy.json"
docker start "$name" >/dev/null
docker exec "$name" sh -eu -c '
 export MC_CONFIG_DIR=/tmp/mc-config
 for i in $(seq 1 30); do
  if mc alias set admin http://127.0.0.1:9000 integration-admin disposable-storage-admin >/dev/null 2>&1; then break; fi
  sleep 1
 done
 mc mb admin/visitaki-preview admin/unrelated-fixture >/dev/null
 mc anonymous set none admin/visitaki-preview >/dev/null
 mc admin policy create admin visitaki-preview /tmp/policy.json >/dev/null
 mc admin user add admin visitaki-preview-app disposable-storage-app-credential >/dev/null
 mc admin policy attach admin visitaki-preview --user visitaki-preview-app >/dev/null
 mc alias set app http://127.0.0.1:9000 visitaki-preview-app disposable-storage-app-credential >/dev/null
 printf synthetic > /tmp/object
 mc cp /tmp/object app/visitaki-preview/test >/dev/null
 test "$(mc cat app/visitaki-preview/test)" = synthetic
 if mc ls app/unrelated-fixture >/dev/null 2>&1; then exit 1; fi
 if mc cp /tmp/object app/unrelated-fixture/test >/dev/null 2>&1; then exit 1; fi
 if mc admin user list app >/dev/null 2>&1; then exit 1; fi
 mc rm app/visitaki-preview/test >/dev/null
 '
printf '%s\n' 'Visitaki bucket round trip passed; unrelated bucket and admin access denied.'
