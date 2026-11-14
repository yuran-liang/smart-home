#!/bin/bash
# SMART health of the backup HDD and of the system SSD, through the device nodes that
# docker-compose.yml maps to /dev/hdd and /dev/ssd (HDD_DEVICE and SSD_DEVICE in docker/.env; a
# disk without a device is skipped).
#
#   check-disk-health.sh          read the SMART status and attributes, alert on a problem
#   check-disk-health.sh short    start a short self-test (the next check reads the result)
#   check-disk-health.sh long     start a long self-test (many hours on a large disk)
#
# An alert is an email and a Nextcloud notification (see lib.sh). HDD_SMART_TYPE and SSD_SMART_TYPE
# are the smartctl -d types; "sat" fits nearly all USB-to-SATA bridges. DISK_MAX_TEMP is the
# temperature in degrees Celsius that raises an alert (default 55).
set -uo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

max_temp=${DISK_MAX_TEMP:-55}
mode=${1:-check}
case "$mode" in
check | short | long) ;;
*)
    echo "Usage: $0 [check|short|long]" >&2
    exit 2
    ;;
esac

status=0

# check_disk <label> <device> <smartctl type>
check_disk() {
    local label=$1 dev=$2 type=$3 out rc msg bad_attrs temp
    local problems=()

    if [ ! -b "$dev" ]; then
        echo "$label: no device configured, skipped."
        return 0
    fi

    if [ "$mode" != check ]; then
        smartctl -d "$type" -t "$mode" "$dev" || {
            alert "$label self-test" "Could not start the $mode SMART self-test on the $label."
            status=1
        }
        return 0
    fi

    out=$(smartctl -d "$type" -H -A -l selftest "$dev")
    rc=$?
    echo "== $label"
    echo "$out"

    # smartctl's exit status is a bit mask: 1 usage, 2 cannot open or read, 4 SMART command failed,
    # 8 disk failing, 16 prefail attribute below threshold, 128 errors in the self-test log
    # (32 and 64 are old history and are not alerted on)
    [ $((rc & 3)) -ne 0 ] && problems+=("cannot read SMART data (smartctl status $rc; wrong ${label}_SMART_TYPE?)")
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
        echo "$label SMART check passed."
        return 0
    fi
    msg=$(printf '%s; ' "${problems[@]}")
    alert "$label problem" "$msg"
    status=1
}

check_disk HDD /dev/hdd "${HDD_SMART_TYPE:-sat}"
check_disk SSD /dev/ssd "${SSD_SMART_TYPE:-sat}"
exit "$status"
