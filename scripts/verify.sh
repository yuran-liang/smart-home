#!/bin/bash
# ok never fails, so "A && ok || bad" is a safe if/else in this script
# shellcheck disable=SC2015
# Check that the stack on this host is healthy. Run it on the Pi after install.sh, a restore or an
# upgrade; it changes nothing and exits non-zero when a check fails.
#
# Usage: scripts/verify.sh
#
# Environment (all optional):
#   HDD_DIR          mount point of the external HDD (default: value in docker/.env, else /mnt/hdd)
#   BACKUP_MAX_AGE_H maximum age in hours of the newest state backup (default: 36)
set -u

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=$REPO/docker/.env
fails=0

ok() { echo "ok    $1"; }
bad() {
    echo "FAIL  $1"
    fails=$((fails + 1))
}
get_env() { grep "^$1=" "$ENV_FILE" 2> /dev/null | head -n 1 | cut -d= -f2-; }
docker_cmd() { if docker info > /dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi; }

HDD_DIR=${HDD_DIR:-$(get_env HDD_DIR)}
HDD_DIR=${HDD_DIR:-/mnt/hdd}
BACKUP_MAX_AGE_H=${BACKUP_MAX_AGE_H:-36}

# System
[ "$(uname -m)" = aarch64 ] && ok "64-bit system" || bad "not a 64-bit system ($(uname -m))"
if mountpoint -q "$HDD_DIR"; then ok "HDD mounted at $HDD_DIR"; else bad "HDD not mounted at $HDD_DIR"; fi
root_use=$(df --output=pcent / | tail -n 1 | tr -dc 0-9)
[ "$root_use" -lt 90 ] && ok "system disk ${root_use}% full" || bad "system disk ${root_use}% full"

# Containers: every service of the Compose file runs, none restarts or is unhealthy
services=$(cd "$REPO/docker" && docker_cmd compose config --services 2> /dev/null)
if [ -z "$services" ]; then
    bad "docker compose config failed"
else
    running=$(cd "$REPO/docker" && docker_cmd compose ps --services --status running 2> /dev/null)
    for s in $services; do
        echo "$running" | grep -qx "$s" && ok "service $s running" || bad "service $s not running"
    done
fi
unhealthy=$(docker_cmd ps --filter health=unhealthy --filter status=restarting --format '{{.Names}}')
[ -z "$unhealthy" ] && ok "no unhealthy or restarting containers" || bad "unhealthy or restarting: $unhealthy"

# Zigbee dongle
dongle=$(get_env ZIGBEE_DONGLE)
if [ -n "$dongle" ] && ! echo "$dongle" | grep -q '<serial>'; then
    [ -e "$dongle" ] && ok "Zigbee dongle present" || bad "Zigbee dongle missing ($dongle)"
fi

# Mosquitto and Node-RED answer on their ports
for port in 1883 1880; do
    if (exec 3<> "/dev/tcp/127.0.0.1/$port") 2> /dev/null; then ok "port $port open"; else bad "port $port closed"; fi
done

# Nextcloud
nc_port=$(get_env NEXTCLOUD_PORT)
nc_port=${nc_port:-8090}
if echo "$services" | grep -qx nextcloud; then
    status=$(curl -s -m 10 "http://127.0.0.1:$nc_port/status.php" || true)
    if echo "$status" | grep -q '"installed":true' && echo "$status" | grep -q '"maintenance":false' &&
        echo "$status" | grep -q '"needsDbUpgrade":false'; then
        ok "Nextcloud installed, no maintenance, no pending upgrade"
    else
        bad "Nextcloud status: ${status:-no answer}"
    fi
    if docker_cmd exec -u www-data nextcloud php occ status 2> /dev/null | grep -q 'installed: true'; then
        ok "occ works"
    else
        bad "occ status failed"
    fi
fi

# Backups
state_dir=$HDD_DIR/backup/smart-home-state
newest=$(find "$state_dir" -name 'state-*.tgz' -mmin "-$((BACKUP_MAX_AGE_H * 60))" 2> /dev/null | head -n 1)
if [ -n "$newest" ]; then
    ok "state backup newer than ${BACKUP_MAX_AGE_H} h"
else
    bad "no state backup newer than ${BACKUP_MAX_AGE_H} h in $state_dir"
fi

# Tailscale (a container; only checked when the stack has one)
if echo "$services" | grep -qx tailscale; then
    if docker_cmd exec tailscale tailscale status > /dev/null 2>&1; then ok "Tailscale connected"; else bad "Tailscale not connected"; fi
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$fails check(s) failed."
    exit 1
fi
