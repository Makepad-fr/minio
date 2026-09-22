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

Application stacks attach to their matching network and connect to the stable service alias for that application. VIF is intentionally production-only in this repository; canary deploys do not create or attach the VIF network.

## Buckets

Use one bucket per application. For Catwlk:

- canary: `${MAKEPAD_MINIO_CATWLK_BUCKET}`
- production: `${MAKEPAD_MINIO_CATWLK_BUCKET}`

For VIF:

- production: `${MAKEPAD_MINIO_VIF_BUCKET}`

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

The tracked `envs/<environment>/.env.minio` files intentionally leave `MINIO_ROOT_PASSWORD` empty. During deployment, the workflow copies the selected env file into a temporary bundle and injects `DEPLOY_MINIO_ROOT_PASSWORD` into that bundle before uploading it to the target host. If the secret is absent, the workflow fails before writing or uploading an empty password.

The workflow deploys only the MinIO stack. If a required objects network does not exist yet, it is created on the manager before deployment. It also ensures the Catwlk bucket exists after the service is updated. Production deploys additionally create the VIF network when needed and ensure the VIF bucket exists.

## Makepad Scan

Scanner assets use private bucket makepad-scan on the existing storage VM. Apply policies/makepad-scan.json to a dedicated service user. Public bucket access is forbidden. The existing host deployment is accessed over the private WireGuard path; do not introduce another MinIO instance.

Provision the scanner on the existing host with `scripts/provision-makepad-scan.sh`.
Supply the existing root credentials and a dedicated `SCAN_STORAGE_PASSWORD`
through protected environment files. The script creates only `makepad-scan` and
`makepad-scan-app`, disables anonymous access and attaches the scoped policy.
It never resets an existing user's password. Keep the password in the Makepad
vault; the application consumes it as a Swarm secret.

`MinIO scanner contracts` runs on the owning repository’s existing Ubuntu runner policy. The
policy stage validates the bucket boundary; the provisioning stage additionally
starts a disposable pinned MinIO container and verifies repeatability, protected
access and credential retention. It does not touch hosted buckets. Replacing the
stale Amiary check requirement with this check needs an explicit repository-owner
decision; this PR does not modify branch protection.

## Visitaki restricted preview

`policies/visitaki-preview.json` scopes the `visitaki-preview-app` identity to
one private bucket, `visitaki-preview`. Production campaign inventory must use
separate storage when the public launch gate is met. No anonymous object access
is enabled; the application serves only reviewed public campaign images.

On the storage host, run `scripts/provision-visitaki-preview.sh` with
`MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, and a vault-managed
`VISITAKI_STORAGE_PASSWORD` (at least 32 characters). The script uses a temporary
private mc configuration, does not rotate an existing user's password, and
verifies authentication with the supplied application credential. If that check
fails, stop and reconcile the vault; do not reset another user's credentials.

The live storage host currently uses standalone host-network containers. This
additive provisioning script does not redeploy the shared stack. Restrict
Visitaki access to the existing private application-to-database path; do not
open the S3 port publicly or change neighboring application policies.

Run `scripts/test-visitaki-policy.sh` against an available Docker context to
verify upload/read/delete and denial of unrelated-bucket and admin access. It
uses a pinned MinIO image, synthetic credentials, no network, and no host ports.
The Visitaki storage isolation PR check runs on a GitHub-hosted Linux runner;
this public repository does not receive shared infrastructure-runner access.
