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

The shared MinIO service joins app-specific external overlay networks:

- Catwlk canary and production: `${DEPLOY_CATWLK_OBJECTS_NETWORK}` with service alias `makepad-minio`
- VIF production only: `${DEPLOY_VIF_OBJECTS_NETWORK}` with service alias `makepad-minio-vif`
- Fashion crawler production only: `${DEPLOY_FASHION_OBJECTS_NETWORK}` with service alias `makepad-minio-fashion`

Application stacks attach to their matching network and connect to the stable service alias for that application. VIF and Fashion are intentionally production-only in this repository; canary deploys do not create or attach those networks.

## Buckets

Use one bucket per application. For Catwlk:

- canary: `${MAKEPAD_MINIO_CATWLK_BUCKET}`
- production: `${MAKEPAD_MINIO_CATWLK_BUCKET}`

For VIF:

- production: `${MAKEPAD_MINIO_VIF_BUCKET}`

For Fashion crawler product data:

- production: `${MAKEPAD_MINIO_FASHION_BUCKET}`

Applications should use their own bucket instead of sharing a global one.

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
- `DEPLOY_MINIO_ROOT_PASSWORD`

Required production-only environment secret:

- `DEPLOY_VIF_OBJECTS_NETWORK`
- `DEPLOY_FASHION_OBJECTS_NETWORK`

The tracked `envs/<environment>/.env.minio` files intentionally leave `MINIO_ROOT_PASSWORD` empty. During deployment, the workflow copies the selected env file into a temporary bundle and injects `DEPLOY_MINIO_ROOT_PASSWORD` into that bundle before uploading it to the target host. If the secret is absent, the workflow fails before writing or uploading an empty password.

The workflow deploys only the MinIO stack. If a required objects network does not exist yet, it is created on the manager before deployment. It also ensures the Catwlk bucket exists after the service is updated. Production deploys additionally create the VIF and Fashion networks when needed and ensure their buckets exist.
