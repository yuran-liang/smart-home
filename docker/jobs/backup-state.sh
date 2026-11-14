#!/bin/bash
# Daily archive of the runtime state (home-config's backup-state.sh) onto the HDD.
set -euo pipefail

# /hdd is bind-mounted from the host. If the HDD was not mounted there, it is a plain directory
# on the system disk and has the same device number as /data: stop instead of filling the disk.
if [ "$(stat -c %d /hdd)" = "$(stat -c %d /data)" ]; then
    echo "The HDD is not mounted; no backup." >&2
    exit 1
fi

DATA_DIR=/data BACKUP_DIR=/hdd/backup/smart-home-state exec /home-config/scripts/backup-state.sh
