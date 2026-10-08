"""Real encrypted snapshot and isolated restore; only disposable resources."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('betacrew-encrypted-backup.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
restic_bin = os.environ.get('RESTIC_BIN') or shutil.which('restic')
assert restic_bin, 'Install restic to run the encrypted restore integration test'
container = 'betacrew-backup-test-' + uuid.uuid4().hex[:12]
image = 'ghcr.io/makepad-fr/visitaki-test-minio@sha256:f6efb212cad3b62f78ca02339f16d8bc28d5bb2fbe792dfc21225c6037d2af8b'

def cmd(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout

with tempfile.TemporaryDirectory(prefix='betacrew-restic-test-') as tmp:
    root = Path(tmp)
    env = dict(os.environ, RESTIC_REPOSITORY=str(root / 'repository'), RESTIC_PASSWORD='disposable-encryption-password')
    def restic(*args, output=subprocess.PIPE):
        return subprocess.run([restic_bin, '--no-cache', *args], env=env, stdout=output, stderr=subprocess.PIPE, check=True, timeout=120).stdout
    restic('init')
    m.ROOT = root / 'backups'
    m.ROOT.mkdir(mode=0o700)
    m.SOURCE, m.IMAGE, m.restic = container, image, restic
    try:
        cmd('docker', 'run', '-d', '--network', 'none', '--name', container, '--tmpfs', '/data:size=268435456', '-e', 'MINIO_ROOT_USER=fixture-admin', '-e', 'MINIO_ROOT_PASSWORD=disposable-admin-password', image, 'server', '/data')
        for _ in range(30):
            try:
                cmd('docker', 'exec', container, 'mc', 'alias', 'set', 'admin', 'http://127.0.0.1:9000', 'fixture-admin', 'disposable-admin-password')
                break
            except subprocess.CalledProcessError:
                time.sleep(1)
        cmd('docker', 'exec', container, 'mc', 'mb', 'admin/betacrew-production', 'admin/unrelated')
        cmd('docker', 'exec', '-i', container, 'mc', 'pipe', 'admin/betacrew-production/nested/image.bin', input=b'private-betacrew-object\x00\xff')
        cmd('docker', 'exec', '-i', container, 'mc', 'pipe', 'admin/unrelated/must-not-backup', input=b'unrelated')
        m.backup()
        receipt = json.loads((m.ROOT / 'latest.json').read_text())
        assert receipt['object_count'] == 1
        snapshot = receipt['snapshot_id']
        # A newer unrelated snapshot must never replace the explicitly selected ID.
        other = root / 'other'; other.mkdir(); (other / 'file').write_text('unrelated')
        rows = [json.loads(line) for line in restic('backup', '--json', '--tag', 'unrelated', str(other)).splitlines()]
        wrong = next(r['snapshot_id'] for r in rows if r.get('message_type') == 'summary')
        try:
            m.restore(wrong)
        except AssertionError:
            pass
        else:
            raise AssertionError('Accepted unrelated snapshot')
        m.restore(snapshot)
        restored = json.loads((m.ROOT / 'restore-receipt.json').read_text())
        assert restored['passed'] and restored['restored_object_count'] == 1
        assert restored['snapshot_id'].startswith(snapshot)
        # The encrypted repository rejects an incorrect password.
        bad_env = dict(env, RESTIC_PASSWORD='incorrect-password')
        assert subprocess.run([restic_bin, 'snapshots'], env=bad_env, capture_output=True).returncode != 0
        print('PASS: encrypted backup, bucket isolation, exact older snapshot, wrong-tag rejection, isolated byte roundtrip and wrong-password rejection')
    finally:
        subprocess.run(['docker', 'rm', '-f', container], capture_output=True)
