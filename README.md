# Makepad MinIO

Shared MinIO deployment for Makepad-fr applications.

This repository owns the shared MinIO server that application repositories connect to over app-specific external overlay networks. Application repositories should not deploy MinIO directly in canary or production.

## Layout

- `compose.yml`: base MinIO service definition
- `envs/canary/compose.yml`: canary Swarm overrides
- `envs/canary/.env.minio`: canary MinIO settings
- `envs/production/compose.yml`: production Swarm overrides
- `envs/production/.env.minio`: production MinIO settings

## Networks

The shared MinIO service joins app-specific external overlay networks. For Catwlk:

- `${DEPLOY_CATWLK_OBJECTS_NETWORK}`

Application stacks attach to the same network and connect to the stable service alias `makepad-minio`.

## Buckets

Use one bucket per application. For Catwlk:

- canary: `${MAKEPAD_MINIO_CATWLK_BUCKET}`
- production: `${MAKEPAD_MINIO_CATWLK_BUCKET}`

Applications should use their own bucket instead of sharing a global one.

BetaCrew uses the private `betacrew-production` bucket and the dedicated
`betacrew-production-app` user. `scripts/provision-betacrew.sh` installs a
bucket-scoped CRUD policy; it does not grant access to any other bucket.

## Node Labels

Pin the shared MinIO server to the database/storage node:

```bash
docker node update --label-add infra.makepad.minio=true <db-node>
```

That label can coexist with `infra.makepad.postgres=true` on the same VM.

## Deployment

Use the manual GitHub Actions workflow in this repository.

Required environment secrets:

- `DEPLOY_SSH_HOST`
- `DEPLOY_SSH_PORT`
- `DEPLOY_SSH_USER`
- `DEPLOY_SSH_PRIVATE_KEY`
- `DEPLOY_REMOTE_DIR`
- `DEPLOY_STACK_NAME`
- `DEPLOY_CATWLK_OBJECTS_NETWORK`

The workflow deploys only the MinIO stack. If the Catwlk objects network does not exist yet, it is created on the manager before deployment. It also ensures the Catwlk bucket exists after the service is updated.

The current two-VM production branch runs MinIO with host networking on the
database/storage VM. Applications reach port 9000 over WireGuard; the console
remains bound to `127.0.0.1`. Add the BetaCrew credential only to the protected
`/etc/makepad/minio/minio.env` file:

```text
MAKEPAD_BETACREW_PRODUCTION_PASSWORD=<generated-secret>
```

The nightly restic job mirrors `betacrew-production` alongside the existing
buckets. After provisioning restic credentials, validate the full write,
backup, restore, byte-compare, and cleanup path with:

```bash
sudo BETACREW_RESTORE_CONFIRM=write-probe-backup-and-restore \
  /srv/makepad/minio/scripts/verify-betacrew-restore.sh
```

The drill uses a temporary probe under `.backup-restore-probe/` and removes it
from live storage when finished.
