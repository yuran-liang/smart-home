#!/bin/bash
# Every five minutes: is the stack healthy? Alerts (email and Nextcloud notification, see lib.sh)
# when something has been wrong for MONITOR_FAIL_AFTER consecutive runs, again every day while it
# stays wrong, and once when it is fine again. Runs in the host network (docker-compose.yml), so
# the ports below are the ones of the services on the Pi.
#
# Checks: every container of the Compose project runs and is not unhealthy; the service ports
# answer (MONITOR_PORTS, "name:port ..."); Nextcloud's status; free space; Tailscale; the Pi's
# supply voltage, throttling and CPU temperature; and, twice a day, the age of the newest backups.
#
# The state of every check is a file in STATE_DIR, so a restart of the container does not repeat
# alerts. Not covered: a dead Pi cannot alert about itself (it needs a check from outside).
set -uo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATE_DIR=${STATE_DIR:-/state/monitor}
FAIL_AFTER=${MONITOR_FAIL_AFTER:-2}
PORTS=${MONITOR_PORTS:-mosquitto:1883 nodered:1880 homebridge:8581 samba:445 portainer:9000}
DISK_MAX_PCT=${MONITOR_DISK_MAX_PCT:-90}
BACKUP_MAX_AGE_H=${BACKUP_MAX_AGE_H:-36}
CPU_MAX_TEMP=${MONITOR_CPU_MAX_TEMP:-80}

mkdir -p "$STATE_DIR"
exec 9> "$STATE_DIR/.lock"
flock -n 9 || exit 0

# report <id> <ok|fail> <message> [remind hours, default 24, 0 = never again]
report() {
    local id=$1 status=$2 msg=$3 remind=${4:-24} file fails=0 alerted=0 now
    file=$STATE_DIR/$id
    now=$(date +%s)
    { read -r fails alerted < "$file"; } 2> /dev/null || {
        fails=0
        alerted=0
    }
    if [ "$status" = ok ]; then
        [ "$alerted" != 0 ] && alert "Recovered: $id" "$msg"
        echo "0 0" > "$file"
        return 0
    fi
    fails=$((fails + 1))
    if [ "$fails" -ge "$FAIL_AFTER" ]; then
        if [ "$alerted" = 0 ]; then
            alert "Problem: $id" "$msg"
            alerted=$now
        elif [ "$remind" != 0 ] && [ $((now - alerted)) -ge $((remind * 3600)) ]; then
            alert "Still failing: $id" "$msg"
            alerted=$now
        fi
    fi
    echo "$fails $alerted" > "$file"
}

# Containers of the Compose project: running, not restarting, not unhealthy
if containers=$(docker ps -a --filter label=com.docker.compose.project --format '{{.Names}} {{.State}} {{.Status}}' 2> /dev/null) &&
    [ -n "$containers" ]; then
    bad=$(echo "$containers" | awk '$2 != "running" || /unhealthy/ { printf "%s (%s) ", $1, $2 }')
    if [ -z "$bad" ]; then report containers ok "All containers run."; else report containers fail "Not running or unhealthy: $bad"; fi
else
    report containers fail "Cannot list the containers (Docker not reachable?)."
fi

# Service ports
for spec in $PORTS; do
    name=${spec%%:*}
    port=${spec##*:}
    if (exec 3<> "/dev/tcp/127.0.0.1/$port") 2> /dev/null; then
        report "port-$name" ok "$name answers on port $port."
    else
        report "port-$name" fail "$name does not answer on port $port."
    fi
done

# Nextcloud: installed, not in maintenance mode, no pending upgrade
status=$(docker exec nextcloud curl -fsS -m 10 http://localhost/status.php 2> /dev/null || true)
if echo "$status" | grep -q '"installed":true' && echo "$status" | grep -q '"maintenance":false' &&
    echo "$status" | grep -q '"needsDbUpgrade":false'; then
    report nextcloud ok "Nextcloud is up."
else
    report nextcloud fail "Nextcloud status: ${status:-no answer}"
fi

# Tailscale
if docker exec tailscale tailscale status > /dev/null 2>&1; then
    report tailscale ok "Tailscale is connected."
else
    report tailscale fail "Tailscale is not connected."
fi

# Free space (statfs only, it does not wake the HDD)
for mount in /data /var/nextcloud/data /hdd; do
    id=disk-$(echo "${mount#/}" | tr / _)
    pct=$(df --output=pcent "$mount" 2> /dev/null | tail -n 1 | tr -dc 0-9)
    if [ -z "$pct" ]; then
        report "$id" fail "Cannot read the free space of $mount."
    elif [ "$pct" -ge "$DISK_MAX_PCT" ]; then
        report "$id" fail "$mount is ${pct}% full."
    else
        report "$id" ok "$mount is ${pct}% full."
    fi
done
if require_hdd 2> /dev/null; then
    report hdd-mounted ok "The HDD is mounted."
else
    report hdd-mounted fail "The HDD is not mounted."
fi

# Raspberry Pi: supply voltage and throttling (get_throttled bits: 0 under-voltage now, 2 throttled
# now, 3 soft temperature limit now, 16 under-voltage since boot, 18 throttled since boot)
throttled_file=$(find /sys/devices -name get_throttled -print -quit 2> /dev/null)
if [ -n "$throttled_file" ] && flags=$(cat "$throttled_file" 2> /dev/null); then
    flags=$((flags))
    if [ $((flags & 0xD)) -ne 0 ]; then
        report pi-power-now fail "The Pi is under-voltage or throttled right now (flags $(printf '0x%x' "$flags")). Check the power supply and cable."
    else
        report pi-power-now ok "No under-voltage or throttling now."
    fi
    # Sticky until the next reboot: say it once, not every day
    if [ $((flags & 0x50000)) -ne 0 ]; then
        report pi-power-history fail "Since the last boot the Pi had under-voltage or throttling (flags $(printf '0x%x' "$flags")). Check the power supply and cable." 0
    else
        report pi-power-history ok "No under-voltage since the last boot." 
    fi
fi
temp_file=/sys/class/thermal/thermal_zone0/temp
if [ -r "$temp_file" ]; then
    temp=$(($(cat "$temp_file") / 1000))
    if [ "$temp" -ge "$CPU_MAX_TEMP" ]; then
        report pi-temperature fail "The CPU is at ${temp} C."
    else
        report pi-temperature ok "The CPU is at ${temp} C."
    fi
fi

# Backups: twice a day, because reading the HDD wakes it
if [ "$(date +%M)" -lt 5 ] && { [ "$(date +%H)" = 08 ] || [ "$(date +%H)" = 20 ]; }; then
    if find /hdd/backup/smart-home-state -name 'state-*.tgz' -mmin "-$((BACKUP_MAX_AGE_H * 60))" 2> /dev/null | grep -q .; then
        report backup-state ok "The state backup is fresh."
    else
        report backup-state fail "No state backup newer than $BACKUP_MAX_AGE_H h."
    fi
    if [ -n "${RESTIC_PASSWORD:-}" ] && [ "$RESTIC_PASSWORD" != change-me ]; then
        snap=$(restic snapshots --host nextcloud --tag files --latest 1 --json 2> /dev/null | jq -r '.[0].time // empty' 2> /dev/null || true)
        if [ -n "$snap" ] && [ "$(date -d "$snap" +%s)" -gt "$(date -d "-$BACKUP_MAX_AGE_H hours" +%s)" ]; then
            report backup-nextcloud ok "The newest Nextcloud snapshot is from $snap."
        else
            report backup-nextcloud fail "No Nextcloud snapshot newer than $BACKUP_MAX_AGE_H h (newest: ${snap:-none})."
        fi
    fi
fi
