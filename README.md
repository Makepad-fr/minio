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

Application stacks attach to their matching network and connect to the stable service alias for that application. VIF is intentionally production-only in this repository; canary deploys do not create or attach the VIF network. Amiary is deliberately not attached to an overlay here: its cross-host data plane must use a separately provisioned private, certificate-verified TLS endpoint. Until that endpoint, CA, and least-privilege credentials are wired into the Amiary stack, photo and export storage remains fail-closed.

## Buckets

Use one bucket per application. For Catwlk:

- canary: `${MAKEPAD_MINIO_CATWLK_BUCKET}`
- production: `${MAKEPAD_MINIO_CATWLK_BUCKET}`

For VIF:

- production: `${MAKEPAD_MINIO_VIF_BUCKET}`

For Amiary:

- canary: `amiary-photos-canary`
- production: `amiary-photos`

Both Amiary buckets have object versioning enabled. Each environment has three
dedicated identities restricted to its own bucket: the application identity
uses `policies/amiary-app.json`, the scheduled backup identity uses the
List/Get-only `policies/amiary-backup.json`, and the manual restore identity
uses `policies/amiary-restore.json`. The application and backup service never
receive MinIO root or restore credentials.

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
- `DEPLOY_SSH_KNOWN_HOSTS`
- `DEPLOY_REMOTE_DIR`
- `DEPLOY_STACK_NAME`
- `DEPLOY_CATWLK_OBJECTS_NETWORK`
- `DEPLOY_MINIO_ROOT_PASSWORD`
- `DEPLOY_AMIARY_ACCESS_KEY`
- `DEPLOY_AMIARY_SECRET_KEY` (at least 32 random characters)
- `DEPLOY_AMIARY_BACKUP_ACCESS_KEY`
- `DEPLOY_AMIARY_BACKUP_SECRET_KEY` (at least 32 random characters)
- `DEPLOY_AMIARY_RESTORE_ACCESS_KEY`
- `DEPLOY_AMIARY_RESTORE_SECRET_KEY` (at least 32 random characters)

Required production-only environment secret:

- `DEPLOY_VIF_OBJECTS_NETWORK`

The tracked `envs/<environment>/.env.minio` files intentionally leave `MINIO_ROOT_PASSWORD` empty. During deployment, the workflow copies the selected env file into a temporary bundle and injects `DEPLOY_MINIO_ROOT_PASSWORD` into that bundle before uploading it to the target host. If the secret is absent, the workflow fails before writing or uploading an empty password.

The workflow deploys only the MinIO stack. If a required existing application network does not exist yet, it is created on the manager before deployment. It also ensures the Catwlk bucket exists after the service is updated. Production deploys additionally create the VIF network when needed and ensure the VIF bucket exists. Amiary bucket and credential provisioning runs as a short-lived operator-side client on the existing MinIO management network; it does not expose MinIO to the Amiary application.

All three access keys and all three secret keys must be distinct. The MinIO server and administration
client images are pinned by digest. Amiary provisioning is repeatable and
verifies exact policy convergence, no administrative access, read-only backup
behavior, and separate restore write/delete behavior:

```bash
scripts/test-amiary-provisioning.sh
```

Credential rotation is coordinated: update the matching GitHub environment
secret pair, deploy the reconciled identity, atomically replace the host's
backup credential file when rotating that identity, and immediately run and
verify a backup. The restore credential remains in the approved secret manager
and is retrieved only for a restore drill or incident. Never reuse an app,
backup, or restore key across environments.

## Amiary Production Backup And Restore

Only the production `amiary-photos` bucket is accepted by the backup and
restore entrypoints. The scripts use the pinned `minio/mc` digest already used
for Amiary provisioning. Backup and restore each have a separate two-line
credential-file contract: line one is the access key and line two is the secret
key. Scheduled backup loads only the List/Get identity. The write/delete restore
credential is root-owned and is loaded only by the explicit manual restore
entrypoint. Each credential file is mounted read-only into a short-lived client
container; its values are never placed in arguments, environment variables,
manifests, or logs.

Amiary encrypts object bodies before upload. Backup therefore copies the stored
ciphertext without possessing or invoking a decryption key. Each run takes a
quiet inventory before and after copying and publishes the snapshot only when
the inventories match, retrying a changing bucket three times. A completed
snapshot contains:

- `objects/`: the current encrypted-object set;
- `source-inventory.jsonl`: the non-logged stability inventory;
- `SHA256SUMS.nul`: filename-safe per-object SHA-256 records;
- `manifest.json` and `CONTROL.SHA256SUMS`: bucket, pinned image, counts, byte
  totals, and control-file integrity;
- `COMPLETE`: written before the staging directory is atomically published.

The operator must mount the Hetzner Storage Box with authenticated encrypted
transport at `/mnt/makepad-storagebox` and provide encryption at rest for that
mount. The scripts fail closed unless both controls are explicitly confirmed.
They also reject symlinked/broad paths and refuse to run if the configured
Storage Box path is not an actual mountpoint.

Copy the non-secret configuration template and install the two operational
credentials separately. Generate them through the approved secret-management
process; do not reuse the app identity or either access key:

```bash
sudo useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin makepad-minio-backup
sudo install -d -o root -g root -m 0755 /etc/makepad
sudo install -d -o root -g root -m 0711 /etc/makepad/secrets /etc/makepad/secrets/minio
sudo install -d -o makepad-minio-backup -g makepad-minio-backup -m 0700 /etc/makepad/secrets/minio/backup
sudo install -m 0600 config/amiary-minio-backup.env.example /etc/makepad/amiary-minio-backup.env
sudo install -o makepad-minio-backup -g makepad-minio-backup -m 0400 /secure/operator/path/amiary-backup.credentials /etc/makepad/secrets/minio/backup/amiary.credentials
sudo install -d -o makepad-minio-backup -g makepad-minio-backup -m 0700 /mnt/makepad-storagebox/amiary-minio
sudo install -d -o makepad-minio-backup -g makepad-minio-backup -m 0700 /var/lib/makepad/amiary-minio-restore
```

Set the existing MinIO management-network name and set both Storage Box confirmations to
`true` only after verifying those controls. Never put access or secret keys in
the environment file. Both identities must remain restricted to
`amiary-photos`; no root credential is required. Do not persist the restore
credential on the host: retrieve it only for an approved restore into the
root-only `/run/makepad/amiary-minio-restore.credentials` path, then remove it.
The service account needs
access to the local Docker socket through the unit's `SupplementaryGroups=docker`;
as with any Docker-socket principal, treat that account as host-privileged and
do not grant it interactive login.

Install the service files after adjusting `/opt/makepad/minio` or the
`ReadWritePaths` directive if the checked-out repository or mounted backup path
differs:

```bash
sudo install -m 0644 systemd/amiary-minio-backup.service /etc/systemd/system/
sudo install -m 0644 systemd/amiary-minio-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now amiary-minio-backup.timer
systemctl list-timers amiary-minio-backup.timer
```

The timer runs at 00:15, 06:15, 12:15, and 18:15 UTC with persistent catch-up,
giving a six-hour backup interval and a six-hour RPO target. Successful backups
automatically prune complete snapshots older than 35 days. Alert on a failed or
late service immediately because a failure invalidates the RPO assumption.
For manual verification, pruning, or restore, load the root-owned non-secret
environment first. Do not place restore acknowledgements in that persistent
file:

```bash
set -a
source /etc/makepad/amiary-minio-backup.env
set +a
```

Pruning can then be inspected or run manually:

```bash
sudo --preserve-env /opt/makepad/minio/scripts/prune-amiary-backups.sh
sudo --preserve-env /opt/makepad/minio/scripts/prune-amiary-backups.sh --apply
```

Verify a snapshot without printing object names or content:

```bash
sudo --preserve-env /opt/makepad/minio/scripts/verify-amiary-backup.sh 20260831T001500Z
```

### Destructive restore runbook

The restore target is the current view of `amiary-photos`: objects absent from
the chosen snapshot are deleted from that view. MinIO versioning provides an
additional recovery layer, but the operation is still destructive. Take a new
snapshot, stop Amiary API/worker object writes, record the incident/change
ticket, verify available restore-work disk space, and stop the timer. Retrieve
the restore credential just in time from the approved secret manager; it must
be the identity provisioned with `policies/amiary-restore.json`, never the app
or backup identity. Install it in the configured ephemeral path, set all three
one-time acknowledgements, and run the restore. Never run this entrypoint from
the backup timer identity:

```bash
set -euo pipefail
sudo systemctl stop amiary-minio-backup.timer
if sudo systemctl is-active --quiet amiary-minio-backup.service; then
  echo 'Amiary MinIO backup is still active; wait for it to finish.' >&2
  exit 1
fi
sudo install -d -o root -g root -m 0700 /run/makepad
sudo install -o root -g root -m 0400 /secure/operator/path/amiary-restore.credentials /run/makepad/amiary-minio-restore.credentials
trap 'sudo rm -f -- /run/makepad/amiary-minio-restore.credentials' EXIT
export AMIARY_RESTORE_CONFIRM_PRODUCTION_BUCKET=amiary-photos
export AMIARY_RESTORE_CONFIRM_REPLACE_CURRENT_OBJECTS=REPLACE_AMIARY_PRODUCTION_OBJECTS
export AMIARY_RESTORE_CONFIRM_WRITES_PAUSED=AMIARY_WRITES_ARE_PAUSED
sudo --preserve-env /opt/makepad/minio/scripts/restore-amiary-bucket.sh 20260831T001500Z
sudo rm -f -- /run/makepad/amiary-minio-restore.credentials
trap - EXIT
sudo systemctl start amiary-minio-backup.timer
unset AMIARY_RESTORE_CONFIRM_PRODUCTION_BUCKET
unset AMIARY_RESTORE_CONFIRM_REPLACE_CURRENT_OBJECTS
unset AMIARY_RESTORE_CONFIRM_WRITES_PAUSED
```

Restore first verifies the stored manifest, performs a quiet exact mirror, then
downloads the resulting current state into `AMIARY_RESTORE_WORK_DIR` and checks
every encrypted object against the original snapshot. Keep writes paused if
either restore or verification fails. The operational RTO target is four hours;
size the Storage Box link and restore-work volume against the largest retained
snapshot, monitor elapsed time, and run an isolated restore drill at least
quarterly and before launch. Record snapshot ID, timestamps, byte count,
result, operator, and ticket without recording object names or content. If the
restore fails, keep writes paused but still remove the ephemeral credential
before investigating; retrieve it again only for a reviewed retry.

Local validation uses only an isolated disposable bucket and temporary paths:

```bash
scripts/test-amiary-backup-static.sh
scripts/test-amiary-backup-disposable.sh
```

`.github/workflows/amiary-contract.yml` runs on every pull request so its
`Amiary provisioning and backup contracts` job can be required by branch
protection. Pushes to `main` are path-filtered. The workflow uses only local
lint and disposable containers and contains no deployment or remote-host step.
