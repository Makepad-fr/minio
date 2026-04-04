# Repository Conventions

## Deploy Layout

- This repository owns the shared MinIO stack.
- Application repositories should consume the shared object-storage network and connect to `makepad-minio`.
- Use app-scoped network secret names in this shared repo, for example `DEPLOY_CATWLK_OBJECTS_NETWORK`.
- Use one bucket per application.
- Canary and production overrides live under `envs/<environment>/compose.yml`.
- MinIO env files live under `envs/<environment>/.env.minio`.

## Placement

- MinIO is pinned with `node.labels.infra.makepad.minio == true`.
- The same node can also carry `node.labels.infra.makepad.postgres == true`.

## Documentation

- Keep `README.md` and workflow instructions aligned with network names, bucket names, and deployment steps.
