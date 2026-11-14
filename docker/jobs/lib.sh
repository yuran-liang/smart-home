#!/bin/bash
# Shared helpers of the scheduled jobs (sourced, not run).

# Tell the Nextcloud admin through a Nextcloud notification. Does nothing without
# NEXTCLOUD_NOTIFY_USER and never fails the calling job (Nextcloud may be the thing that is down).
notify() {
    [ -n "${NEXTCLOUD_NOTIFY_USER:-}" ] || return 0
    docker exec -u www-data nextcloud php occ notification:generate "$NEXTCLOUD_NOTIFY_USER" "$1" -l "$2" > /dev/null 2>&1 || true
}

# /hdd is bind-mounted from the host. If the HDD was not mounted there, it is a plain directory
# on the system disk and has the same device number as /data: stop instead of filling the disk.
require_hdd() {
    if [ "$(stat -c %d /hdd)" = "$(stat -c %d /data)" ]; then
        echo "The HDD is not mounted." >&2
        return 1
    fi
}
