import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('visitaki-encrypted-backup.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ObjectIntegrity(unittest.TestCase):
    def test_nested_object_keys_and_empty_bucket(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(module.checksums(root), {})
            (root / 'campaigns' / 'demo').mkdir(parents=True)
            (root / 'campaigns' / 'demo' / 'image.jpg').write_bytes(b'synthetic image bytes')
            self.assertEqual(module.checksums(root), {'campaigns/demo/image.jpg': hashlib.sha256(b'synthetic image bytes').hexdigest()})

    def test_changed_bytes_change_restore_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'image.jpg'
            path.write_bytes(b'before')
            before = module.checksums(root)
            path.write_bytes(b'after')
            self.assertNotEqual(module.checksums(root), before)

    def test_symlink_cannot_enter_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'outside').symlink_to('/etc/passwd')
            with self.assertRaises(AssertionError):
                module.checksums(root)


if __name__ == '__main__':
    unittest.main()
