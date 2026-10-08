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
# Visitaki object backup

On `db-server-1`, `scripts/visitaki-encrypted-backup.py backup` reads only the
`visitaki-preview` bucket and writes an encrypted snapshot to the existing MinIO
Restic repository. Credentials remain inside the existing MinIO container and
the root-owned Restic environment file. Temporary plaintext objects are removed
after the attempt; repository snapshots and shared retention are unchanged.

The pilot normalizes uploaded campaign images to JPEG, with their MIME type and
object references in PostgreSQL. This backup preserves current object keys and
bytes. Database references require the separate Visitaki PostgreSQL backup;
storage users and bucket policies are provisioned from reviewed configuration.

Run `restore --snapshot <id>` to retrieve the encrypted snapshot, verify its
manifest, restore it to an isolated MinIO container with no network or published
ports, and compare every object after a second download. Use a synthetic private
test object to prove a nonempty restore during initial activation. Only after
that succeeds, install the script as
`/srv/makepad/visitaki-backups/visitaki-minio-backup.py` and enable the two
`systemd/visitaki-minio-backup.*` units. Root-owned receipts are stored under
`/var/lib/makepad/visitaki-minio-backup`.

## Fashion private storage

The Fashion Iceberg provisioner operates only on the existing standalone MinIO
container; it does not recreate shared storage or attach Swarm networks. Supply
`MINIO_ICEBERG_ACCESS_KEY=scraping-iceberg` and a protected
`MINIO_ICEBERG_SECRET_KEY` of at least32 characters, then run
`bash scripts/provision-fashion-iceberg.sh` with the established Docker context.
The optional `MINIO_CONTAINER_NAME` selects the existing server. The bucket and
policy remain fixed to `fashion-iceberg` and `scraping-iceberg-writer`.

The script uses the server's installed client and existing root environment,
passes the application password through stdin, and removes its private client
configuration afterward. It never resets an existing password, disables anonymous
bucket access, and verifies the application credential. The real-container test
checks repeatability, scoped writes, cross-bucket/admin denial and retention of
the original password after a mismatched-password attempt. No production
provisioning is implied by passing this disposable test.

## BetaCrew private object storage

`scripts/provision-betacrew.sh` provisions only `betacrew-production` and its
`betacrew-production-app` identity. Supply `MAKEPAD_BETACREW_PRODUCTION_PASSWORD`
(at least 32 characters) through the protected execution environment. Existing
credentials and unexpected policy assignments cause validation failure rather
than credential rotation. The bucket remains private. The script uses the
existing MinIO container and does not install host services or alter shared topology.

`scripts/betacrew-encrypted-backup.py backup` exports only this bucket to the
protected restic repository configured by the host administrator. Run it on
`db-server-1` with the existing root-only backup environment. It records the exact
snapshot ID and does not prune backups. `restore --snapshot ID` verifies the
bucket tag, source path and checksums, then round-trips objects through a disposable
network-isolated MinIO container. It never writes restored data into production.
Production activation requires an encrypted backup and successful restore receipt;
local provisioning tests alone do not satisfy that gate. No timer is installed by
this change. Run `bash scripts/validate-betacrew-config.sh` for disposable provisioning
and object-integrity tests.

## Amiary scoped provisioning

Provision Amiary separately with `scripts/provision-amiary.sh`, using the existing
management network and distinct application, backup and restore credential files.
This PR does not connect its application data plane, change shared MinIO resource
limits or require Amiary secrets for unrelated deployments. Existing credentials
and unexpected direct/group policy assignments are rejected without rotation.
Credential rotation needs a separate coordinated operation.

## Amiary Production Backup And Restore

Only the production `amiary-photos` bucket is accepted by the backup and
restore entrypoints. The scripts use the pinned internal MinIO client fixture already used
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
sudo install -d -o root -g root -m 0700 /var/lib/makepad/amiary-minio-restore
```

The backup credential and backup root must be owned by the timer's primary
user and group. The just-in-time restore credential and restore work directory
must likewise be owned by the root operator identity used by the restore
runbook. The entrypoints reject ownership drift, then run each `mc` container
as that exact numeric UID/GID with a private, identity-owned tmpfs. This keeps
the production credentials at `0400` while allowing neither container root nor
an unrelated host identity to become an implicit credential reader.

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

The pinned client fixture requires GHCR read access on the operator host. The original Docker Hub digests are unavailable; live provisioning remains gated on verified host access and topology.
