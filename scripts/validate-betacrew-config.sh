#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bash -n "$root/scripts/provision-betacrew.sh" "$root/scripts/verify-betacrew-restore.sh"
python3 "$root/scripts/test-betacrew-backup.py"
bash "$root/scripts/test-betacrew-provisioning.sh"
