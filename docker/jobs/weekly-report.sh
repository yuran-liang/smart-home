#!/bin/bash
# Monday morning email with the state of the house server: problems that are open right now, free
# space, the newest backups, and the traffic of the guest exit node. Email only (a report is not an
# alert); does nothing without the SMTP settings.
set -uo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MONITOR_STATE=${MONITOR_STATE:-/state/monitor}
USAGE_CSV=${USAGE_CSV:-/state/guest-exit/usage.csv}

{
    echo "Open problems:"
    open=
    for f in "$MONITOR_STATE"/*; do
        [ -f "$f" ] || continue
        read -r _ alerted < "$f" 2> /dev/null || continue
        if [ "${alerted:-0}" != 0 ]; then
            echo "  - $(basename "$f")"
            open=1
        fi
    done
    [ -n "$open" ] || echo "  none"

    echo
    echo "Free space:"
    df -h --output=target,size,used,pcent /data /var/nextcloud/data /hdd 2> /dev/null | sed 's/^/  /'

    echo
    echo "Newest backups:"
    echo "  state:     $(find /hdd/backup/smart-home-state -name 'state-*.tgz' -printf '%TY-%Tm-%Td %TH:%TM\n' 2> /dev/null | sort | tail -n 1)"
    if [ -n "${RESTIC_PASSWORD:-}" ] && [ "$RESTIC_PASSWORD" != change-me ]; then
        echo "  Nextcloud: $(restic snapshots --host nextcloud --tag files --latest 1 --json 2> /dev/null | jq -r '.[0].time // "none"' 2> /dev/null)"
    fi

    echo
    echo "Guest exit traffic (received / sent):"
    if [ -f "$USAGE_CSV" ]; then
        week=$(date -d '-7 days' +%F)
        month=$(date +%Y-%m)
        awk -F, -v w="$week" -v m="$month" '
            $1 >= w { wr += $2; ws += $3 }
            index($1, m) == 1 { mr += $2; ms += $3 }
            END {
                printf "  last 7 days: %.1f GiB / %.1f GiB\n", wr / 1073741824, ws / 1073741824
                printf "  this month:  %.1f GiB / %.1f GiB\n", mr / 1073741824, ms / 1073741824
            }' "$USAGE_CSV"
    else
        echo "  no data"
    fi
} > /tmp/weekly-report.txt

cat /tmp/weekly-report.txt
send_email "Weekly report" "$(cat /tmp/weekly-report.txt)"
