#!/bin/bash
# SMART health of the backup HDD, through the device that docker-compose.yml maps to /dev/hdd
# (HDD_DEVICE in docker/.env; without it this does nothing).
#
#   check-hdd-health.sh          read the SMART status and attributes, alert on a problem
#   check-hdd-health.sh short    start a short self-test (the next check reads the result)
#   check-hdd-health.sh long     start a long self-test (many hours on a large disk)
#
# An alert is a Nextcloud notification for NEXTCLOUD_NOTIFY_USER (and the container log).
# HDD_SMART_TYPE is the smartctl -d type; "sat" fits nearly all USB-to-SATA bridges.
# HDD_MAX_TEMP is the temperature in degrees Celsius that raises an alert (default 55).
set -uo pipefail

# shellcheck source=lib.sh
. /jobs/lib.sh

dev=/dev/hdd
type=${HDD_SMART_TYPE:-sat}
max_temp=${HDD_MAX_TEMP:-55}
mode=${1:-check}

if [ ! -b "$dev" ]; then
    echo "HDD_DEVICE is not set: no SMART check."
    exit 0
fi

case "$mode" in
short | long)
    smartctl -d "$type" -t "$mode" "$dev" || {
        notify "HDD self-test" "Could not start the $mode SMART self-test on the backup HDD."
        exit 1
    }
    exit 0
    ;;
check) ;;
*)
    echo "Usage: $0 [check|short|long]" >&2
    exit 2
    ;;
esac

problems=()
out=$(smartctl -d "$type" -H -A -l selftest "$dev")
rc=$?
echo "$out"

# smartctl's exit status is a bit mask: 1 usage, 2 cannot open or read, 4 SMART command failed,
# 8 disk failing, 16 prefail attribute below threshold, 128 errors in the self-test log
# (32 and 64 are old history and are not alerted on)
[ $((rc & 3)) -ne 0 ] && problems+=("cannot read SMART data (smartctl status $rc; wrong HDD_SMART_TYPE?)")
[ $((rc & 8)) -ne 0 ] && problems+=("SMART overall health is FAILED")
[ $((rc & 16)) -ne 0 ] && problems+=("a pre-failure attribute is below its threshold")
[ $((rc & 128)) -ne 0 ] && problems+=("the self-test log has errors")

# Raw values of the attributes that usually precede a failure: reallocated sectors (5), pending
# sectors (197), uncorrectable sectors (198)
bad_attrs=$(echo "$out" | awk '$1 == 5 || $1 == 197 || $1 == 198 { if ($10 + 0 > 0) printf "%s=%s ", $2, $10 }')
[ -n "$bad_attrs" ] && problems+=("SMART counters above zero: $bad_attrs")

temp=$(echo "$out" | awk '$1 == 194 || $1 == 190 { print $10 + 0; exit }')
if [ -n "$temp" ] && [ "$temp" -ge "$max_temp" ]; then
    problems+=("temperature ${temp} C")
fi

if [ "${#problems[@]}" -eq 0 ]; then
    echo "HDD SMART check passed."
    exit 0
fi
msg=$(printf '%s; ' "${problems[@]}")
echo "HDD problem: $msg" >&2
notify "Backup HDD problem" "$msg"
exit 1
