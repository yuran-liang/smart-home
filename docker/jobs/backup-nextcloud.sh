#!/bin/bash
# Nightly Nextcloud backup onto the HDD: a restic repository with the data directory, a database
# dump and config.php. Every run is an incremental snapshot, so the repository keeps a history
# (see KEEP_* below) for little more space than one copy.
#
# Restore (docker/README.md): docker exec jobs restic snapshots; docker exec jobs restic restore ...
#
# Environment: RESTIC_REPOSITORY and RESTIC_PASSWORD (set by docker-compose.yml), optionally
# KEEP_DAILY, KEEP_WEEKLY, KEEP_MONTHLY, NEXTCLOUD_NOTIFY_USER (a failure sends a notification).
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEP_DAILY=${KEEP_DAILY:-7}
KEEP_WEEKLY=${KEEP_WEEKLY:-4}
KEEP_MONTHLY=${KEEP_MONTHLY:-6}
DATA=/var/nextcloud/data
host=nextcloud
tmp=

cleanup() {
    status=$?
    [ -z "$tmp" ] || rm -f "$tmp"
    if [ "$status" -ne 0 ]; then
        echo "Nextcloud backup failed." >&2
        alert "Nextcloud backup failed" "The nightly backup to the HDD failed; see: docker logs jobs"
    fi
}
trap cleanup EXIT

# The first run takes hours; never let a second one start on top of it
exec 9> /tmp/backup-nextcloud.lock
flock -n 9 || {
    echo "A backup is already running."
    exit 0
}

require_hdd
if [ -z "${RESTIC_PASSWORD:-}" ] || [ "$RESTIC_PASSWORD" = change-me ]; then
    echo "NEXTCLOUD_BACKUP_PASSWORD is not set in docker/.env." >&2
    exit 1
fi
[ -d "$DATA" ] || {
    echo "$DATA is not mounted into the container." >&2
    exit 1
}

low_priority() {
    if command -v ionice > /dev/null 2>&1; then
        nice -n 19 ionice -c 3 "$@"
    else
        nice -n 19 "$@"
    fi
}
restic() { low_priority restic "$@"; }

if [ ! -f "$RESTIC_REPOSITORY/config" ]; then
    echo "==> Creating the restic repository"
    mkdir -p "$RESTIC_REPOSITORY"
    restic init
fi

# Order matters: the database first, then the files. A file that is newer than the dump is picked up
# by "occ files:scan" after a restore; a dump that is newer than the files would point at files
# that are not in the backup. A failed dump must not become a snapshot, so it goes through a file.
mkdir -p /hdd/backup
tmp=$(mktemp /hdd/backup/.nextcloud-dump.XXXXXX)

echo "==> Database"
docker exec nextcloud-db sh -c 'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction nextclouddb' |
    gzip > "$tmp"
gzip -t "$tmp"
restic backup --host "$host" --tag db --stdin --stdin-filename nextclouddb.sql.gz < "$tmp"

echo "==> config.php"
docker exec nextcloud cat /var/www/html/config/config.php > "$tmp"
[ -s "$tmp" ]
restic backup --host "$host" --tag config --stdin --stdin-filename config/config.php < "$tmp"
rm -f "$tmp"
tmp=

echo "==> Files"
# Previews are generated again on demand
restic backup --host "$host" --tag files --exclude "$DATA/appdata_*/preview" "$DATA"

echo "==> Retention"
restic forget --host "$host" --group-by host,tags \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY"

# Freeing space and checking the repository read a lot: once a week, on Sundays
if [ "$(date +%u)" = 7 ]; then
    echo "==> Prune and check"
    restic prune
    restic check --read-data-subset=2%
fi

echo "Nextcloud backup done."
