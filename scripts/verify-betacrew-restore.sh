#!/usr/bin/env bash
set -euo pipefail
: "${BETACREW_RESTORE_SNAPSHOT:?set the exact BetaCrew snapshot ID to verify}"
root=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$root/scripts/betacrew-encrypted-backup.py" restore --snapshot "$BETACREW_RESTORE_SNAPSHOT"
