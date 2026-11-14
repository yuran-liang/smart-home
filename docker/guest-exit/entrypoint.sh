#!/bin/sh
# Start Tailscale, and keep the firewall rules in place while it runs.
set -eu

# The private ranges are blocked before Tailscale starts; only the own address is added later
/guest-exit/firewall.sh

/usr/local/bin/containerboot &
boot=$!

# Tailscale only gets an address after it is logged in, so wait for it. The rules are applied
# again every 30 seconds in case Tailscale restarts and rebuilds its own rules.
(
    while true; do
        ip=$(tailscale ip -4 2> /dev/null | head -n 1 || true)
        if [ -n "$ip" ]; then
            /guest-exit/firewall.sh "$ip"
        fi
        sleep 30
    done
) &

wait "$boot"
