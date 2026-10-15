#!/usr/bin/env python3
"""Exercise actual snapshot validation with disposable local files."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SnapshotIntegrity(unittest.TestCase):
    def test_manifest_records(self):
        for mutation in ("valid", "duplicate", "unterminated"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                snapshot = Path(tmp) / "20261013T120000Z"
                (snapshot / "objects").mkdir(parents=True)
                (snapshot / "objects/a").write_bytes(b"aaaa")
                (snapshot / "objects/b").write_bytes(b"bbbb")
                (snapshot / "source-inventory.jsonl").write_text("{}\n{}\n")
                env = dict(os.environ, AMIARY_MINIO_BUCKET="amiary-photos")
                prelude = 'source "$1"; '
                result = subprocess.run(["bash", "-c", prelude + 'write_snapshot_manifests "$2" 20261013T120000Z 2026-10-13T12:00:00Z', "test", str(ROOT / "scripts/amiary-backup-lib.sh"), str(snapshot)], env=env, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                checksums = snapshot / "SHA256SUMS.nul"
                if mutation == "duplicate":
                    record = hashlib.sha256(b"aaaa").hexdigest().encode() + b"  objects/a\0"
                    checksums.write_bytes(record * 2)
                    (snapshot / "objects/b").write_bytes(b"oops")
                elif mutation == "unterminated":
                    checksums.write_bytes(checksums.read_bytes() + b"unparsed trailing corruption")
                control = "".join(hashlib.sha256((snapshot / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in ("manifest.json", "SHA256SUMS.nul", "source-inventory.jsonl"))
                (snapshot / "CONTROL.SHA256SUMS").write_text(control)
                result = subprocess.run(["bash", "-c", prelude + 'verify_snapshot "$2"', "test", str(ROOT / "scripts/amiary-backup-lib.sh"), str(snapshot)], env=env, capture_output=True)
                if mutation == "valid":
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                else:
                    self.assertNotEqual(result.returncode, 0, "Accepted " + mutation + " checksum manifest")

if __name__ == "__main__":
    unittest.main()
