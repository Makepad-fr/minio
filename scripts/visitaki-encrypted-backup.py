#!/usr/bin/env python3
"""Back up only Visitaki's private image bucket; verify a no-network restore."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path('/var/lib/makepad/visitaki-minio-backup')
ENV = Path('/etc/makepad/backups/restic-minio.env')
SOURCE = 'minio-minio-1'
BUCKET = 'visitaki-preview'
IMAGE = 'quay.io/minio/minio@sha256:d249d1fb6966de4d8ad26c04754b545205ff15a62e4fd19ebd0f26fa5baacbc0'


def run(args, **kwargs):
    result = subprocess.run(args, stderr=subprocess.PIPE, timeout=600, **kwargs)
    if result.returncode:
        raise RuntimeError('Visitaki object backup operation failed: ' + args[0])
    return result


def restic(*args, output=subprocess.PIPE):
    return run(['/bin/bash', '-ec', 'set -a; source "$1"; shift; exec /usr/bin/restic --no-cache "$@"',
        'visitaki-objects', str(ENV), *args], stdout=output).stdout


def checksums(directory):
    result = {}
    for path in sorted(directory.rglob('*')):
        assert not path.is_symlink(), 'Object snapshot must not contain symlinks'
        if path.is_file():
            with path.open('rb') as stream:
                result[str(path.relative_to(directory))] = hashlib.file_digest(stream, 'sha256').hexdigest()
    return result


def backup():
    current = ROOT / 'current'
    assert not current.exists(), 'Unfinished snapshot requires inspection'
    current.mkdir(mode=0o700)
    objects = current / 'objects'
    objects.mkdir(mode=0o700)
    remote = '/tmp/visitaki-object-backup-' + uuid.uuid4().hex
    try:
        # Existing administrative credentials stay inside the MinIO container.
        # Only this constant Visitaki bucket is read; no policy or object changes.
        script = '''set -eu
umask 077
mkdir -p "$1/config" "$1/objects"
export MC_CONFIG_DIR="$1/config"
mc alias set source http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mirror source/visitaki-preview "$1/objects" >/dev/null
rm -rf "$1/config"
'''
        run(['docker', 'exec', SOURCE, 'sh', '-ec', script, 'visitaki-backup', remote], stdout=subprocess.DEVNULL)
        run(['docker', 'cp', SOURCE + ':' + remote + '/objects/.', str(objects)], stdout=subprocess.DEVNULL)
        metadata = {'bucket': BUCKET, 'objects': checksums(objects), 'created_unix': int(time.time())}
        (current / 'metadata.json').write_text(json.dumps(metadata))
        output = restic('backup', '--json', '--host', 'db-server-1', '--tag', 'visitaki-preview-objects', str(current))
        summaries = [json.loads(line) for line in output.splitlines() if line.strip()]
        summary = [row for row in summaries if row.get('message_type') == 'summary']
        assert len(summary) == 1 and summary[0].get('snapshot_id')
        receipt = {'snapshot_id': summary[0]['snapshot_id'], 'bucket': BUCKET,
                   'object_count': len(metadata['objects']), 'encrypted_repository': True}
        (ROOT / 'latest.json').write_text(json.dumps(receipt, indent=2))
        print(json.dumps(receipt))
    finally:
        subprocess.run(['docker', 'exec', SOURCE, 'rm', '-rf', remote], capture_output=True, timeout=30)
        shutil.rmtree(current)


def restore(snapshot):
    assert re.fullmatch('[0-9a-f]{8,64}', snapshot)
    records = json.loads(restic('snapshots', '--json', snapshot))
    assert len(records) == 1 and 'visitaki-preview-objects' in records[0].get('tags', [])
    assert records[0]['paths'] == [str(ROOT / 'current')]
    container = 'visitaki-minio-restore-' + uuid.uuid4().hex[:12]
    created = False
    with tempfile.TemporaryDirectory(prefix='restore-', dir=ROOT) as temporary:
        directory = Path(temporary)
        restic('restore', snapshot, '--target', str(directory))
        restored = directory / str(ROOT / 'current').lstrip('/')
        metadata = json.loads((restored / 'metadata.json').read_text())
        assert metadata['bucket'] == BUCKET
        assert checksums(restored / 'objects') == metadata['objects']
        try:
            run(['docker', 'run', '-d', '--name', container, '--network', 'none', '--cpus', '.5', '--memory', '512m',
                 '--label', 'makepad.validation=visitaki-objects', '-e', 'MINIO_ROOT_USER=restore-validation',
                 '-e', 'MINIO_ROOT_PASSWORD=disposable-restore-validation', IMAGE, 'server', '/data'], stdout=subprocess.DEVNULL)
            created = True
            script = '''set -eu
export MC_CONFIG_DIR=/tmp/restore-config
for attempt in $(seq 1 60); do
 if mc alias set restore http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; then
  mc mb restore/visitaki-preview >/dev/null
  exit 0
 fi
 sleep 1
done
exit 1
'''
            run(['docker', 'exec', container, 'sh', '-ec', script], stdout=subprocess.DEVNULL)
            run(['docker', 'cp', str(restored / 'objects'), container + ':/tmp/restore-objects'], stdout=subprocess.DEVNULL)
            run(['docker', 'exec', container, 'sh', '-ec',
                 'export MC_CONFIG_DIR=/tmp/restore-config; mc mirror /tmp/restore-objects restore/visitaki-preview >/dev/null; mkdir /tmp/roundtrip; mc mirror restore/visitaki-preview /tmp/roundtrip >/dev/null'], stdout=subprocess.DEVNULL)
            roundtrip = directory / 'roundtrip'
            roundtrip.mkdir()
            run(['docker', 'cp', container + ':/tmp/roundtrip/.', str(roundtrip)], stdout=subprocess.DEVNULL)
            assert checksums(roundtrip) == metadata['objects']
            receipt = {'snapshot_id': records[0]['id'], 'bucket': BUCKET, 'image': IMAGE,
                       'restored_object_count': len(metadata['objects']), 'network': 'none',
                       'roundtrip_checksums_verified': True, 'passed': True}
            (ROOT / 'restore-receipt.json').write_text(json.dumps(receipt, indent=2))
            print(json.dumps(receipt))
        finally:
            if created:
                run(['docker', 'rm', '-fv', container], stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['backup', 'restore'])
    parser.add_argument('--snapshot')
    args = parser.parse_args()
    assert os.geteuid() == 0 and socket.gethostname() == 'db-server-1'
    assert ENV.is_file() and not ENV.is_symlink() and ENV.stat().st_uid == 0 and ENV.stat().st_mode & 0o077 == 0
    os.umask(0o077)
    ROOT.mkdir(mode=0o700, exist_ok=True)
    assert ROOT.is_dir() and not ROOT.is_symlink()
    with (ROOT / 'operation.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.operation == 'backup':
            backup()
        else:
            restore(args.snapshot or json.loads((ROOT / 'latest.json').read_text())['snapshot_id'])


if __name__ == '__main__':
    main()
