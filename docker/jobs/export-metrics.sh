#!/bin/bash
# Once a minute: write what the other jobs know (open problems of the monitor, the time of the
# newest backups, the guest exit traffic) as Prometheus text for node-exporter's textfile collector
# (METRICS_DIR, mounted into node-exporter by the metrics profile). Reads small files only; it never
# touches the HDD. Harmless when the metrics profile is off.
set -uo pipefail

MONITOR_STATE=${MONITOR_STATE:-/state/monitor}
USAGE_CSV=${USAGE_CSV:-/state/guest-exit/usage.csv}
METRICS_DIR=${METRICS_DIR:-/state/metrics}
mkdir -p "$METRICS_DIR"
tmp=$(mktemp "$METRICS_DIR/.home.XXXXXX")
trap 'rm -f "$tmp"' EXIT

{
    echo "# HELP home_check_problem 1 while the monitor reports a problem for this check."
    echo "# TYPE home_check_problem gauge"
    for f in "$MONITOR_STATE"/*; do
        [ -f "$f" ] || continue
        id=$(basename "$f")
        case "$id" in newest-* | .*) continue ;; esac
        read -r _ alerted < "$f" 2> /dev/null || continue
        [[ "$alerted" =~ ^[0-9]+$ ]] || continue
        if [ "$alerted" != 0 ]; then echo "home_check_problem{check=\"$id\"} 1"; else echo "home_check_problem{check=\"$id\"} 0"; fi
    done

    echo "# HELP home_backup_newest_timestamp_seconds Time of the newest backup, as the monitor last saw it."
    echo "# TYPE home_backup_newest_timestamp_seconds gauge"
    for kind in state nextcloud; do
        ts=$(cat "$MONITOR_STATE/newest-$kind" 2> /dev/null || true)
        [[ "$ts" =~ ^[0-9]+$ ]] && echo "home_backup_newest_timestamp_seconds{kind=\"$kind\"} $ts"
    done

    if [ -f "$USAGE_CSV" ]; then
        echo "# HELP home_guest_exit_bytes Traffic of the guest exit node (day = last full day, month = this month)."
        echo "# TYPE home_guest_exit_bytes gauge"
        month=$(date +%Y-%m)
        tail -n 1 "$USAGE_CSV" | awk -F, '{ printf "home_guest_exit_bytes{period=\"day\",direction=\"received\"} %d\nhome_guest_exit_bytes{period=\"day\",direction=\"sent\"} %d\n", $2, $3 }'
        awk -F, -v m="$month" 'index($1, m) == 1 { r += $2; s += $3 }
            END { printf "home_guest_exit_bytes{period=\"month\",direction=\"received\"} %d\nhome_guest_exit_bytes{period=\"month\",direction=\"sent\"} %d\n", r, s }' "$USAGE_CSV"
    fi
} > "$tmp"

chmod 644 "$tmp"
mv -f "$tmp" "$METRICS_DIR/home.prom"
