#!/bin/bash
# Daily traffic of the guest exit node: the byte counters of its tailscale0 interface (everything
# the guest sends through the house, in both directions) are read once a day and the difference to
# the last reading is appended to STATE_DIR/usage.csv as "date,bytes received,bytes sent". The
# counters start at zero when the container restarts, which the script treats as a new baseline.
# Without a guest-exit container it does nothing.
#
# With GUEST_EXIT_MONTHLY_LIMIT_GB set (a number), an alert is raised once a month when the traffic
# of the current month passes it. Nothing is limited or blocked.
set -uo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATE_DIR=${STATE_DIR:-/state/guest-exit}
LIMIT_GB=${GUEST_EXIT_MONTHLY_LIMIT_GB:-0}
mkdir -p "$STATE_DIR"

if ! docker inspect --format '{{.State.Running}}' guest-exit 2> /dev/null | grep -q true; then
    echo "No guest-exit container."
    exit 0
fi

# After "tailscale0:" the fields are: received bytes, packets, ... (9th field) sent bytes
read -r rx tx < <(docker exec guest-exit cat /proc/net/dev | sed -n 's/^ *tailscale0: *//p' | awk '{ print $1, $9 }')
if [ -z "${rx:-}" ] || [ -z "${tx:-}" ]; then
    echo "Could not read the tailscale0 counters of guest-exit." >&2
    exit 1
fi

last_rx=0
last_tx=0
[ -f "$STATE_DIR/last" ] && read -r last_rx last_tx < "$STATE_DIR/last"
echo "$rx $tx" > "$STATE_DIR/last"
if [ "$rx" -lt "$last_rx" ] || [ "$tx" -lt "$last_tx" ]; then
    last_rx=0
    last_tx=0
fi
d_rx=$((rx - last_rx))
d_tx=$((tx - last_tx))
echo "$(date +%F),$d_rx,$d_tx" >> "$STATE_DIR/usage.csv"
echo "Guest exit today: $((d_rx / 1048576)) MiB received, $((d_tx / 1048576)) MiB sent."

if [ "$LIMIT_GB" != 0 ]; then
    month=$(date +%Y-%m)
    total=$(awk -F, -v m="$month" 'index($1, m) == 1 { s += $2 + $3 } END { printf "%d", s }' "$STATE_DIR/usage.csv")
    if [ "$total" -ge $((LIMIT_GB * 1073741824)) ] && [ "$(cat "$STATE_DIR/limit-alerted" 2> /dev/null)" != "$month" ]; then
        alert "Guest exit traffic" "The guest exit node has carried $((total / 1073741824)) GiB in $month (limit $LIMIT_GB GiB). Nothing is blocked."
        echo "$month" > "$STATE_DIR/limit-alerted"
    fi
fi
